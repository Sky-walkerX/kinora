// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import CoreImage
import Darwin
import Foundation
import ImageIO
import KinoraKit
import Testing
import UniformTypeIdentifiers
@testable import KinoraMedia

/// Living Photos on real photos: portraits, groups, fur, hair, branches, landscapes and narrow
/// strips (Tests/Fixtures/living-photos.tsv). Runs only when KINORA_EVAL_PHOTOS names a folder
/// of photos; CI's "Living Photo evaluation" workflow downloads them and uploads what this
/// writes to KINORA_EVAL_OUT, so a person can look at the frames.
///
/// For each photo it records what Vision found, how long generation took and how much memory it
/// needed, whether the loop's seam is as smooth as any other step, what decoding the loop costs
/// the CPU, and what drawing the same frames in real time would cost instead. Numbers from CI's
/// virtual Mac are not a real Mac's; the shape of the comparison is what they are for.
@Suite(.serialized) struct LivingPhotoEvaluation {
    static let photos = ProcessInfo.processInfo.environment["KINORA_EVAL_PHOTOS"]
    static let output = CGSize(width: 2940, height: 1912)

    @Test(.enabled(if: photos != nil))
    func evaluateRealPhotos() async throws {
        let environment = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: try #require(Self.photos), isDirectory: true)
        let results = URL(fileURLWithPath: environment["KINORA_EVAL_OUT"] ?? NSTemporaryDirectory() + "kinora-eval", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let photos = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!photos.isEmpty)
        var lines: [String] = []
        for photo in photos {
            let line = try await evaluate(photo, into: results)
            print("EVAL \(line)")
            lines.append(line)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: results.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    }

    private func evaluate(_ photo: URL, into results: URL) async throws -> String {
        let name = photo.deletingPathExtension().lastPathComponent
        let folder = results.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let work = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let original = try Data(contentsOf: photo)

        // Generation, as the app runs it, with this process's memory sampled throughout.
        let sampler = FootprintSampler()
        let wall = Date()
        let result = try await LivingPhotoGenerator.generate(photo: photo, output: Self.output, workFolder: work)
        let wallSeconds = Date().timeIntervalSince(wall)
        let peakMB = sampler.stop()
        #expect(try Data(contentsOf: photo) == original, "the photo must only be read")

        // Frames to look at: the start, the furthest sideways, a close-up of the gap, and each layer.
        let renderer = try LivingPhotoRenderer(photo: photo, output: Self.output)
        let half = Self.output.width / 2
        try write(renderer.image(at: 0, width: half), to: folder.appendingPathComponent("frame-000.jpg"))
        try write(renderer.image(at: 0.25, width: half), to: folder.appendingPathComponent("frame-025.jpg"))
        try write(renderer.image(at: 0.75, width: half), to: folder.appendingPathComponent("frame-075.jpg"))
        if let layer = renderer.layerFrame(at: 0.25, subjectOnly: false) {
            try write(image(layer, renderer, width: half), to: folder.appendingPathComponent("background-025.jpg"))
        }
        if let layer = renderer.layerFrame(at: 0.25, subjectOnly: true) {
            try write(image(layer, renderer, width: half), to: folder.appendingPathComponent("subject-025.jpg"))
        }
        if let closeUp = gapCloseUp(renderer) {
            try write(closeUp, to: folder.appendingPathComponent("gap-closeup-025.jpg"))
        }

        // The finished video: is the loop's seam as smooth as any other step, and what does decoding cost?
        let playback = try await decode(result.video)
        // Drawing the same frames live instead: Core Image compositing at full size.
        let live = liveCompositeMilliseconds(renderer, frames: 45)

        let subject = renderer.plan.subject.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
        let size = (try? photoSize(photo)) ?? .zero
        let metrics: [String: Any] = [
            "photo": name, "photoWidth": Int(size.width), "photoHeight": Int(size.height),
            "subjects": result.detection.count, "coverage": result.detection.coverage, "lifted": result.detection.lifted,
            "detectionFailure": result.detection.failure ?? NSNull(),
            "prepareSeconds": result.prepareSeconds, "encodeSeconds": result.encodeSeconds, "wallSeconds": wallSeconds,
            "peakFootprintMB": peakMB, "codec": result.codec, "megabytes": Double(result.bytes) / 1_000_000,
            "seamLumaDiff": playback.seam, "meanStepLumaDiff": playback.meanStep, "maxStepLumaDiff": playback.maxStep,
            "decodeWallSeconds": playback.wallSeconds, "decodeCPUSeconds": playback.cpuSeconds, "videoSeconds": playback.videoSeconds,
            "liveCompositeMsPerFrame": live,
        ]
        let json = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: folder.appendingPathComponent("metrics.json"))
        #expect(result.bytes > 0)
        #expect(playback.frames == renderer.plan.frameCount)
        // The seam may be no rougher than the roughest ordinary step, with a little slack for encoding.
        #expect(playback.seam <= playback.maxStep * 1.5 + 0.5, "\(name): the loop's seam jumps")

        func f(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }
        return "\(name) \(Int(size.width))x\(Int(size.height)): subjects \(result.detection.count), coverage \(f(result.detection.coverage, 3)), "
            + "lifted \(result.detection.lifted), subject box \(subject), prepare \(f(result.prepareSeconds)) s, encode \(f(result.encodeSeconds)) s, "
            + "wall \(f(wallSeconds)) s, peak footprint \(f(peakMB, 0)) MB, \(result.codec) \(f(Double(result.bytes) / 1_000_000, 1)) MB; "
            + "seam luma diff \(f(playback.seam)) vs steps mean \(f(playback.meanStep)) max \(f(playback.maxStep)); "
            + "decode \(f(playback.cpuSeconds)) CPU s for \(f(playback.videoSeconds, 0)) s of video "
            + "(\(f(playback.cpuSeconds / max(0.001, playback.videoSeconds) * 100, 1))% of a core); "
            + "live composite \(f(live, 1)) ms/frame (\(f(live * 30 / 10, 1))% of 30 fps frame time)"
    }

    // MARK: - Pieces

    /// A full-resolution crop beside the subject at the loop's widest point, where the filled gap shows.
    private func gapCloseUp(_ renderer: LivingPhotoRenderer) -> CGImage? {
        guard let subject = renderer.plan.subject else { return nil }
        let t = 0.25
        let placed = renderer.plan.subjectPlacement(at: t).apply(subject, about: renderer.plan.center)
        let crop = renderer.plan.crop
        // The subject moves right of its background here, so the gap opens on its left.
        let side = 720.0
        var rect = CGRect(x: placed.minX - crop.minX - side * 0.6, y: placed.midY - crop.minY - side * 0.4, width: side, height: side * 0.8)
        rect = rect.intersection(CGRect(origin: .zero, size: renderer.plan.output)).integral
        guard rect.width > 16, rect.height > 16 else { return nil }
        return renderer.context.createCGImage(renderer.frame(at: t).cropped(to: rect), from: rect, format: .RGBA8,
                                              colorSpace: LivingPhotoRenderer.sRGB)
    }

    private func image(_ layer: CIImage, _ renderer: LivingPhotoRenderer, width: Double) -> CGImage? {
        let scale = width / renderer.plan.output.width
        let scaled = layer.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        return renderer.context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8, colorSpace: LivingPhotoRenderer.sRGB)
    }

    private func write(_ image: CGImage?, to url: URL) throws {
        let image = try #require(image)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func photoSize(_ url: URL) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(LivingPhotoRenderer.orientedSize(source))
    }

    struct Playback {
        var frames = 0
        var seam = 0.0, meanStep = 0.0, maxStep = 0.0
        var wallSeconds = 0.0, cpuSeconds = 0.0, videoSeconds = 0.0
    }

    /// Decodes every frame the way playback does (to the decoder's native 4:2:0 format), timing
    /// it, and compares sampled luma between neighbouring frames, and between the last and first.
    private func decode(_ video: URL) async throws -> Playback {
        let asset = AVURLAsset(url: video)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        var playback = Playback()
        playback.videoSeconds = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        #expect(reader.startReading())
        let cpuStart = Memory.cpuSeconds(), wallStart = Date()
        var first: [UInt8]?, previous: [UInt8]?
        var steps: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let luma = sampledLuma(buffer)
            if let previous { steps.append(meanDifference(previous, luma)) }
            if first == nil { first = luma }
            previous = luma
            playback.frames += 1
        }
        playback.cpuSeconds = Memory.cpuSeconds() - cpuStart
        playback.wallSeconds = Date().timeIntervalSince(wallStart)
        if let first, let previous { playback.seam = meanDifference(previous, first) }
        playback.meanStep = steps.isEmpty ? 0 : steps.reduce(0, +) / Double(steps.count)
        playback.maxStep = steps.max() ?? 0
        return playback
    }

    /// Every 16th luma sample in both directions.
    private func sampledLuma(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return [] }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var out: [UInt8] = []
        out.reserveCapacity((width / 16 + 1) * (height / 16 + 1))
        for y in stride(from: 0, to: height, by: 16) { for x in stride(from: 0, to: width, by: 16) { out.append(bytes[y * row + x]) } }
        return out
    }

    private func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total = 0
        for i in a.indices { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
    }

    /// Milliseconds per frame to composite the two layers into a full-size buffer, as a live
    /// renderer in the plug-in would have to every frame.
    private func liveCompositeMilliseconds(_ renderer: LivingPhotoRenderer, frames: Int) -> Double {
        let width = Int(renderer.plan.output.width), height = Int(renderer.plan.output.height)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &buffer)
        guard let buffer else { return -1 }
        let space = CGColorSpace(name: CGColorSpace.itur_709) ?? LivingPhotoRenderer.sRGB
        renderer.render(at: 0, into: buffer, colorSpace: space) // warm up
        let start = Date()
        for index in 0..<frames { renderer.render(at: Double(index) / Double(frames), into: buffer, colorSpace: space) }
        return Date().timeIntervalSince(start) * 1000 / Double(frames)
    }
}

/// The largest physical footprint this process reaches while it runs, sampled every 20 ms.
/// (The kernel's own "interval" maximum turned out not to reset between photos.)
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))

    init() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    /// Stops sampling and returns the peak in MB.
    func stop() -> Double {
        timer.cancel()
        sample()
        return lock.withLock { Double(peak) / 1_048_576 }
    }

    private func sample() {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return }
        lock.withLock { peak = max(peak, info.ri_phys_footprint) }
    }
}

/// This process's CPU time.
enum Memory {
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
