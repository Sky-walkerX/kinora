// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import CoreVideo
import Foundation
import KinoraKit
@testable import KinoraMedia
import Testing

/// Converts the synthetic fixtures in Tests/Fixtures/containers (ffmpeg's testsrc2, 96×64,
/// 10 frames) and compares every frame with AVFoundation's own decode of `hevc.mp4`, made from
/// the same pattern, so wrong colours, wrong frames or a wrong order all show.
@Suite(.serialized, .timeLimit(.minutes(3))) struct MatroskaConverterTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/containers", isDirectory: true)
    static let display = CGSize(width: 2560, height: 1600)

    func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kinora-mkv-\(UUID().uuidString)-\(name).mov")
    }

    /// Every frame's luma plane, as AVFoundation decodes `url`.
    static func lumaFrames(_ url: URL) async throws -> [[UInt8]] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var frames: [[UInt8]] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            var luma: [UInt8] = []
            luma.reserveCapacity(width * height)
            for y in 0..<height { luma.append(contentsOf: UnsafeBufferPointer(start: base + y * row, count: width)) }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames.append(luma)
        }
        return frames
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    }

    @Test(arguments: ["vp9.webm", "vp9.mkv", "vp9-live.webm", "vp9-altref.webm", "vp9-10bit.webm", "vp9-alpha.webm", "h264.mkv", "hevc.mkv", "av1.webm"])
    func convertsAndMatchesTheReference(name: String) async throws {
        let output = temporary(name)
        defer { try? FileManager.default.removeItem(at: output) }
        let result: MatroskaConversion
        do {
            result = try await MatroskaConverter.convert(Self.fixtures.appendingPathComponent(name), to: output, display: Self.display)
        } catch MatroskaConversionError.decoderUnavailable(let codec) where name == "av1.webm" {
            // AV1 decodes only where the Mac has a decoder for it.
            print("MKV \(name): this Mac has no \(codec) decoder")
            #expect(!FileManager.default.fileExists(atPath: output.path))
            return
        }
        print("MKV \(name): \(result)")
        #expect(result.frames == 10 && result.width == 96 && result.height == 64)
        #expect(abs(result.seconds - 1) < 0.05)
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.isPlayable))
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.05)

        let converted = try await Self.lumaFrames(output)
        let reference = try await Self.lumaFrames(Self.fixtures.appendingPathComponent("hevc.mp4"))
        #expect(converted.count == 10 && reference.count == 10)
        guard converted.count == reference.count, converted.count > 2 else { return }
        let aligned = zip(converted, reference).map { Self.difference($0, $1) }
        let shifted = zip(converted.dropFirst(), reference).map { Self.difference($0, $1) }
        let alignedMean = aligned.reduce(0, +) / Double(aligned.count)
        let shiftedMean = shifted.reduce(0, +) / Double(shifted.count)
        print("MKV \(name): luma difference per frame \(aligned.map { String(format: "%.1f", $0) }.joined(separator: " ")), shifted by one \(String(format: "%.1f", shiftedMean))")
        // Two lossy encodings of the same pattern differ a little; a wrong frame or order differs more.
        #expect(alignedMean < 10, "frames look wrong: \(aligned)")
        #expect(alignedMean < shiftedMean, "frames are out of order")
        #expect(aligned.allSatisfy { $0 < shifted.max() ?? .infinity })
    }

    @Test func vp8IsExplainedNotConverted() async throws {
        let output = temporary("vp8")
        await #expect(throws: MatroskaConversionError.unsupportedCodec("VP8")) {
            try await MatroskaConverter.convert(Self.fixtures.appendingPathComponent("vp8.webm"), to: output, display: Self.display)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(MatroskaConversionError.unsupportedCodec("VP8").description.contains("VP8"))
    }

    @Test func otherFilesAreNotMatroska() async throws {
        await #expect(throws: MatroskaConversionError.notMatroska) {
            try await MatroskaConverter.convert(Self.fixtures.appendingPathComponent("hevc.mp4"), to: temporary("mp4"), display: Self.display)
        }
        #expect(MatroskaConverter.isMatroska(Self.fixtures.appendingPathComponent("vp9.webm")))
        #expect(!MatroskaConverter.isMatroska(Self.fixtures.appendingPathComponent("hevc.mp4")))
        // By content, whatever the name.
        let renamed = FileManager.default.temporaryDirectory.appendingPathComponent("kinora-\(UUID().uuidString).video")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("vp9.mkv"), to: renamed)
        defer { try? FileManager.default.removeItem(at: renamed) }
        #expect(MatroskaConverter.isMatroska(renamed))
    }

    @Test func cutOffFilesKeepWhatTheyHave() async throws {
        // Half the file: the frames before the cut are converted.
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("vp9.webm"))
        let cut = FileManager.default.temporaryDirectory.appendingPathComponent("kinora-\(UUID().uuidString).webm")
        try data.prefix(data.count / 2).write(to: cut)
        defer { try? FileManager.default.removeItem(at: cut) }
        let output = temporary("cut")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await MatroskaConverter.convert(cut, to: output, display: Self.display)
        #expect(result.frames > 0 && result.frames < 10)
        // Only the header: nothing to decode.
        try data.prefix(400).write(to: cut)
        await #expect(throws: MatroskaConversionError.self) {
            try await MatroskaConverter.convert(cut, to: output, display: Self.display)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func cancellingStopsAndLeavesNothing() async throws {
        let output = temporary("cancel")
        let task = Task {
            try await MatroskaConverter.convert(Self.fixtures.appendingPathComponent("vp9.webm"), to: output, display: Self.display)
        }
        task.cancel()
        await #expect(throws: MatroskaConversionError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
