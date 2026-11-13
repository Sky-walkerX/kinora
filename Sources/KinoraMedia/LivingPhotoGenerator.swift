// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import KinoraKit
import UniformTypeIdentifiers

/// A finished Living Photo, still in the work folder it was made in.
public struct LivingPhotoResult: Sendable {
    public var video: URL
    public var thumbnail: URL
    public var plan: LivingPhotoPlan
    public var detection: SubjectDetection
    /// "hevc" or "h264".
    public var codec: String
    public var bytes: Int64
    /// Seconds spent lifting the subject and filling the gap.
    public var prepareSeconds: Double
    /// Seconds spent rendering and encoding the frames.
    public var encodeSeconds: Double
}

/// Turns a still photo into a seamless looping video that plays through Kinora's ordinary video
/// path, on the desktop and Lock Screen, with every power rule. The photo itself is only read.
public enum LivingPhotoGenerator {
    /// Makes `living.mov` and `thumbnail.png` in `workFolder`. `progress` runs on a background
    /// thread with values from 0 to 1. Cancelling the task stops the work and removes what it wrote.
    public static func generate(photo: URL, output: CGSize, motion: LivingPhotoMotion = .subtle, seconds: Double = 12,
                                framesPerSecond: Int = 30, workFolder: URL,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> LivingPhotoResult {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LivingPhotoResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let video = workFolder.appendingPathComponent("living.mov")
                    let thumbnail = workFolder.appendingPathComponent("thumbnail.png")
                    do {
                        try flag.check()
                        progress(0.02)
                        let renderer = try LivingPhotoRenderer(photo: photo, output: output, motion: motion, seconds: seconds,
                                                               framesPerSecond: framesPerSecond, flag: flag)
                        progress(0.15)
                        try writeThumbnail(renderer, to: thumbnail)
                        let started = Date()
                        let codec = try encode(renderer, to: video, flag: flag) { done in progress(0.15 + 0.85 * done) }
                        let bytes = ((try? FileManager.default.attributesOfItem(atPath: video.path))?[.size] as? NSNumber)?.int64Value ?? 0
                        continuation.resume(returning: LivingPhotoResult(
                            video: video, thumbnail: thumbnail, plan: renderer.plan, detection: renderer.detection, codec: codec,
                            bytes: bytes, prepareSeconds: renderer.prepareSeconds, encodeSeconds: Date().timeIntervalSince(started)))
                    } catch {
                        // Nothing half-made is left behind.
                        try? FileManager.default.removeItem(at: video)
                        try? FileManager.default.removeItem(at: thumbnail)
                        continuation.resume(throwing: flag.isCancelled ? LivingPhotoError.cancelled : error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// A still of the loop's first frame, at most 1280 pixels wide.
    static func writeThumbnail(_ renderer: LivingPhotoRenderer, to url: URL) throws {
        guard let image = renderer.image(at: 0, width: 1280),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw LivingPhotoError.cannotRender }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LivingPhotoError.writeFailed("the thumbnail could not be written") }
    }

    /// Renders every frame of the loop into a video, HEVC where the Mac can encode it, else
    /// H.264. Returns the codec used.
    static func encode(_ renderer: LivingPhotoRenderer, to url: URL, flag: CancellationFlag,
                       progress: (Double) -> Void) throws -> String {
        let plan = renderer.plan
        let width = Int(plan.output.width), height = Int(plan.output.height)
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) } catch { throw LivingPhotoError.writeFailed(error.localizedDescription) }

        let bitrate = VideoOptimization.bitrate(width: plan.output.width, height: plan.output.height, framesPerSecond: Double(plan.framesPerSecond))
        func settings(_ codec: AVVideoCodecType) -> [String: Any] {
            [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: plan.framesPerSecond,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                ] as [String: Any],
            ]
        }
        let codec: AVVideoCodecType
        if writer.canApply(outputSettings: settings(.hevc), forMediaType: .video) {
            codec = .hevc
        } else if writer.canApply(outputSettings: settings(.h264), forMediaType: .video) {
            codec = .h264
        } else {
            throw LivingPhotoError.encoderUnavailable
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings(codec))
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw LivingPhotoError.encoderUnavailable }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.startWriting() else { throw LivingPhotoError.writeFailed(writer.error?.localizedDescription ?? "the video could not start") }
        writer.startSession(atSourceTime: .zero)
        let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? LivingPhotoRenderer.sRGB

        func abandon(_ error: LivingPhotoError) -> LivingPhotoError {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return error
        }

        let frames = plan.frameCount
        for index in 0..<frames {
            if flag.isCancelled { throw abandon(.cancelled) }
            // The encoder works in the background; wait for room, but never forever.
            var waited = 0
            while !input.isReadyForMoreMediaData {
                if flag.isCancelled { throw abandon(.cancelled) }
                if writer.status == .failed || waited > 30_000 { throw abandon(.writeFailed(writer.error?.localizedDescription ?? "the encoder stopped")) }
                usleep(1000)
                waited += 1
            }
            guard let pool = adaptor.pixelBufferPool else { throw abandon(.writeFailed(writer.error?.localizedDescription ?? "no frame buffers")) }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                throw abandon(.writeFailed("out of memory for frames"))
            }
            renderer.render(at: plan.phase(ofFrame: index), into: buffer, colorSpace: colorSpace)
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(plan.framesPerSecond))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw abandon(.writeFailed(writer.error?.localizedDescription ?? "a frame could not be encoded"))
            }
            if index % 6 == 0 || index == frames - 1 { progress(Double(index + 1) / Double(frames)) }
        }
        input.markAsFinished()
        // The last frame lasts one frame, so the loop is exactly frameCount frames long.
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(plan.framesPerSecond)))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw LivingPhotoError.writeFailed(writer.error?.localizedDescription ?? "the video could not be finished")
        }
        return codec == .hevc ? "hevc" : "h264"
    }
}
