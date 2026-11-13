// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import KinoraKit
import Vision

/// Why a Living Photo could not be made, in words for the user.
public enum LivingPhotoError: Error, Equatable, LocalizedError, Sendable {
    case unreadablePhoto
    case photoTooLarge(width: Int, height: Int)
    case cannotRender
    case encoderUnavailable
    case writeFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreadablePhoto:
            "Kinora can't read this photo. Try a JPEG, HEIC or PNG file."
        case let .photoTooLarge(width, height):
            "This photo is \(width) × \(height) pixels, more than Kinora can work with. Try one under 200 megapixels."
        case .cannotRender:
            "Kinora couldn't draw this photo. Your Mac's graphics may be busy; try again."
        case .encoderUnavailable:
            "This Mac can't encode HEVC or H.264 video, which Living Photos need."
        case let .writeFailed(reason):
            "Kinora couldn't save the Living Photo: \(reason)"
        case .cancelled:
            "Cancelled."
        }
    }
}

/// A flag one thread sets and another reads, for stopping long work.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }

    func check() throws { if isCancelled { throw LivingPhotoError.cancelled } }
}

/// What subject detection found.
public struct SubjectDetection: Equatable, Sendable {
    /// Separate subjects Vision found; zero when it found none or failed.
    public var count: Int
    /// The fraction of the photo the subjects cover.
    public var coverage: Double
    /// Set when detection could not run, so the photo moves as one layer.
    public var failure: String?
    /// True when the subjects are lifted onto their own layer.
    public var lifted: Bool

    public static let none = SubjectDetection(count: 0, coverage: 0, failure: nil, lifted: false)
}

/// A photo prepared as two layers, the lifted subject and the background with the subject's
/// place filled, ready to draw any moment of the loop. Preparing is the slow part (a second or
/// so); each frame afterwards is a cheap GPU composite. Immutable once made, and Core Image
/// contexts are thread-safe, so it may be used from any thread.
public final class LivingPhotoRenderer: @unchecked Sendable {
    public private(set) var plan: LivingPhotoPlan
    public let detection: SubjectDetection
    /// Seconds spent detecting the subject and filling the gap.
    public let prepareSeconds: Double
    private let background: CIImage
    private let subject: CIImage?
    private let context: CIContext

    /// The largest photo Kinora opens, in pixels: decoding is downsampled to the canvas anyway,
    /// but this keeps a malformed file from asking for gigabytes.
    public static let maxPhotoPixels = 200_000_000

    nonisolated(unsafe) static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Prepares `photo` for display at `output` pixels. Throws `LivingPhotoError`.
    public convenience init(photo url: URL, output: CGSize, motion: LivingPhotoMotion = .subtle,
                            seconds: Double = 12, framesPerSecond: Int = 30, flag: CancellationFlag = CancellationFlag()) throws {
        // Core Image's default linear working space, as in the spike: blurs mix light, not gamma.
        let context = CIContext(options: [.cacheIntermediates: false])
        try self.init(photo: url, output: output, motion: motion, seconds: seconds, framesPerSecond: framesPerSecond, flag: flag, context: context)
    }

    init(photo url: URL, output: CGSize, motion: LivingPhotoMotion, seconds: Double, framesPerSecond: Int,
         flag: CancellationFlag, context: CIContext) throws {
        let started = Date()
        self.context = context
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let size = Self.orientedSize(source) else { throw LivingPhotoError.unreadablePhoto }
        guard Int(size.width) * Int(size.height) <= Self.maxPhotoPixels else {
            throw LivingPhotoError.photoTooLarge(width: Int(size.width), height: Int(size.height))
        }
        guard var plan = LivingPhotoPlan.make(photo: size, output: output, subject: nil, motion: motion,
                                              seconds: seconds, framesPerSecond: framesPerSecond) else { throw LivingPhotoError.unreadablePhoto }
        try flag.check()

        // 1. The photo, decoded no larger than the canvas needs, then scaled to cover it exactly.
        let canvasRect = CGRect(origin: .zero, size: plan.canvas)
        let decodeSide = Int(max(plan.canvas.width, plan.canvas.height).rounded(.up))
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeSide,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw LivingPhotoError.unreadablePhoto }
        let scaled = CIImage(cgImage: decoded)
            .transformed(by: CGAffineTransform(scaleX: plan.canvas.width / Double(decoded.width), y: plan.canvas.height / Double(decoded.height)))
        // Materialized once, so every later step reads pixels instead of re-running the decode.
        guard let canvasImage = context.createCGImage(scaled, from: canvasRect, format: .RGBA8, colorSpace: Self.sRGB) else {
            throw LivingPhotoError.cannotRender
        }
        let photo = CIImage(cgImage: canvasImage)
        try flag.check()

        // 2. The subject, from Vision. A failure or an unusable mask leaves one moving layer.
        var detection = SubjectDetection.none
        var mask: CIImage?
        do {
            let found = try Self.detectSubjects(in: canvasImage)
            if let found {
                let (bounds, coverage) = Self.measure(mask: found.mask, canvas: canvasRect, context: context)
                detection = SubjectDetection(count: found.count, coverage: coverage, failure: nil, lifted: false)
                if let bounds, LivingPhotoPlan.isUsableSubject(coverage: coverage),
                   let framed = LivingPhotoPlan.make(photo: size, output: output, subject: Self.toPhoto(bounds, plan: plan),
                                                     motion: motion, seconds: seconds, framesPerSecond: framesPerSecond) {
                    plan = framed
                    mask = found.mask
                    detection.lifted = true
                }
            }
        } catch {
            detection.failure = error.localizedDescription
        }
        try flag.check()
        self.plan = plan
        self.detection = detection

        // 3. Fill the subject's place and lift the subject, or keep the photo whole.
        if let mask {
            let layers = try Self.layers(photo: photo, mask: mask, plan: plan, context: context, flag: flag)
            background = layers.background
            subject = layers.subject
        } else {
            background = photo
            subject = nil
        }
        prepareSeconds = Date().timeIntervalSince(started)
    }

    /// The same layers with different motion; the gap is filled wide enough for any motion.
    /// Call it from the thread that draws frames.
    public func setMotion(_ motion: LivingPhotoMotion) { plan.motion = motion }

    /// The picture at loop phase `t` in [0, 1), `output`-sized with its origin at zero.
    public func frame(at t: Double) -> CIImage {
        let crop = plan.crop
        var image = place(background, plan.backgroundPlacement(at: t))
        if let subject { image = place(subject, plan.subjectPlacement(at: t)).composited(over: image) }
        return image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    /// A frame as a bitmap image, scaled to `width` pixels wide when given, for previews and thumbnails.
    public func image(at t: Double, width: Double? = nil) -> CGImage? {
        var picture = frame(at: t)
        if let width, width < plan.output.width {
            let scale = width / plan.output.width
            picture = picture.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        let extent = picture.extent.integral
        return context.createCGImage(picture, from: extent, format: .RGBA8, colorSpace: Self.sRGB)
    }

    /// Draws the frame at `t` into a pixel buffer the size of the output.
    func render(at t: Double, into buffer: CVPixelBuffer, colorSpace: CGColorSpace) {
        context.render(frame(at: t), to: buffer, bounds: CGRect(origin: .zero, size: plan.output), colorSpace: colorSpace)
    }

    private func place(_ image: CIImage, _ p: LayerPlacement) -> CIImage {
        let c = plan.center
        return image.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: p.scale, y: p.scale))
            .concatenating(CGAffineTransform(translationX: c.x + p.dx, y: c.y + p.dy)))
    }

    // MARK: - Preparation

    /// The image's size after its EXIF orientation is applied.
    static func orientedSize(_ source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Vision's foreground instances: every subject in one mask, canvas-sized. Nil when there are none.
    static func detectSubjects(in image: CGImage) throws -> (mask: CIImage, count: Int)? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        return (CIImage(cvPixelBuffer: buffer), observation.allInstances.count)
    }

    /// The mask's bounds on the canvas (y up) and the fraction of the canvas it covers, from a
    /// small copy: precise enough for framing, and fast.
    static func measure(mask: CIImage, canvas: CGRect, context: CIContext) -> (bounds: CGRect?, coverage: Double) {
        let side = 256.0
        let scale = side / max(canvas.width, canvas.height)
        let tiny = mask.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = max(1, Int((canvas.width * scale).rounded(.down))), h = max(1, Int((canvas.height * scale).rounded(.down)))
        var pixels = [UInt8](repeating: 0, count: w * h)
        context.render(tiny, toBitmap: &pixels, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .L8, colorSpace: nil)
        var minX = w, minY = h, maxX = -1, maxY = -1, covered = 0
        for y in 0..<h {
            for x in 0..<w where pixels[y * w + x] > 127 {
                covered += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let coverage = Double(covered) / Double(w * h)
        guard maxX >= minX else { return (nil, coverage) }
        // Bitmap rows run top to bottom; Core Image's y runs bottom to top.
        let bounds = CGRect(x: Double(minX) / scale, y: canvas.height - Double(maxY + 1) / scale,
                            width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
        return (bounds, coverage)
    }

    /// Canvas pixels to photo pixels.
    static func toPhoto(_ rect: CGRect, plan: LivingPhotoPlan) -> CGRect {
        CGRect(x: rect.minX / plan.photoScale, y: rect.minY / plan.photoScale,
               width: rect.width / plan.photoScale, height: rect.height / plan.photoScale)
    }

    /// The background with the subject's place filled, and the subject on its own, both
    /// materialized as bitmaps so frames only move and composite them.
    static func layers(photo: CIImage, mask: CIImage, plan: LivingPhotoPlan, context: CIContext,
                       flag: CancellationFlag) throws -> (background: CIImage, subject: CIImage) {
        // Sized for the most motion, so changing motion later never shows the photo's subject in the gap.
        var widest = plan
        widest.motion = .lively
        let fill = widest.fill
        let canvas = CGRect(origin: .zero, size: plan.canvas)
        let mask = mask.cropped(to: canvas)

        // Pull the edge in a little, so the subject layer carries none of the background.
        let softMask = mask.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: fill.edgeInset])
            .clampedToExtent().applyingGaussianBlur(sigma: fill.edgeSoftness).cropped(to: canvas)
        // The gap excludes every subject pixel from the colour sampling.
        let gap = mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: fill.gapGrowth])
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.25]).cropped(to: canvas)
        let keep = gap.applyingFilter("CIColorInvert")
        let kept = photo.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: keep])

        // Normalized convolution, blurring sideways only so the gap takes colour from the
        // background at the same height: blur(photo × keep) / blur(keep), nearest scale winning.
        func sideways(_ image: CIImage, _ radius: Double) -> CIImage {
            image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: 0.0]).cropped(to: canvas)
        }
        func level(_ radius: Double) -> (fill: CIImage, confidence: CIImage) {
            let numerator = sideways(kept, radius), denominator = sideways(keep, radius)
            let safe = denominator.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.02, y: 0.02, z: 0.02, w: 1)])
            let divided = safe.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: numerator])
            // Confidence ramps from 0 at 15% coverage to 1 at 45%.
            let confidence = denominator.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 3.33, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 3.33, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 3.33, w: 0), "inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0),
            ]).applyingFilter("CIColorClamp")
            return (divided, confidence)
        }
        var smooth = level(fill.fillRadii[0]).fill
        for radius in fill.fillRadii.dropFirst() {
            let next = level(radius)
            smooth = next.fill.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: smooth, kCIInputMaskImageKey: next.confidence])
        }
        smooth = smooth.clampedToExtent().applyingGaussianBlur(sigma: fill.streakSoftness).cropped(to: canvas)
        try flag.check()

        // The photo's own grain, carried into the gap from beside it.
        let w = Int(canvas.width), h = Int(canvas.height)
        func pixels(_ image: CIImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            context.render(image, toBitmap: &buffer, rowBytes: w * 4, bounds: canvas, format: .RGBA8, colorSpace: sRGB)
            return buffer
        }
        let base = pixels(photo)
        let blurred = pixels(photo.clampedToExtent().applyingGaussianBlur(sigma: fill.detailSoftness).cropped(to: canvas))
        var flat = pixels(smooth)
        let gapPixels = pixels(gap)
        try flag.check()
        let inGap = (0..<(w * h)).map { gapPixels[$0 * 4] > 32 }
        guard try TextureTransfer.apply(photo: base, blurred: blurred, fill: &flat, gap: inGap, width: w, height: h,
                                        isCancelled: { flag.isCancelled }) else { throw LivingPhotoError.cancelled }
        // Opaque: the fill sits under the photo, and alpha from the multiply must not leak through.
        for i in 0..<(w * h) { flat[i * 4 + 3] = 255 }
        let textured = CIImage(bitmapData: Data(flat), bytesPerRow: w * 4, size: canvas.size, format: .RGBA8, colorSpace: sRGB)

        let seam = gap.clampedToExtent().applyingGaussianBlur(sigma: fill.seamSoftness).cropped(to: canvas)
        let background = textured.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: photo, kCIInputMaskImageKey: seam])
        let subject = photo.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: softMask])
        try flag.check()
        guard let backgroundImage = context.createCGImage(background, from: canvas, format: .RGBA8, colorSpace: sRGB),
              let subjectImage = context.createCGImage(subject, from: canvas, format: .RGBA8, colorSpace: sRGB)
        else { throw LivingPhotoError.cannotRender }
        return (CIImage(cgImage: backgroundImage), CIImage(cgImage: subjectImage))
    }
}
