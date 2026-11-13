// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import KinoraKit
import Testing
import UniformTypeIdentifiers
@testable import KinoraMedia

/// Photos drawn by the tests themselves, so no fixture needs a license.
enum SyntheticPhoto {
    /// A sky, textured ground, and a dark figure standing in the middle.
    static func figure(width: Int = 1600, height: Int = 1200, in folder: URL, name: String = "figure.png") throws -> URL {
        try draw(width: width, height: height, in: folder, name: name) { context, w, h in
            // Sky: a vertical gradient.
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let sky = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.35, green: 0.55, blue: 0.85, alpha: 1),
                                                                CGColor(red: 0.85, green: 0.9, blue: 0.95, alpha: 1)] as CFArray, locations: [1, 0])!
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.4), end: CGPoint(x: 0, y: h), options: [])
            // Ground with a fine, deterministic texture.
            var seed: UInt32 = 12345
            for y in stride(from: 0, to: Int(h * 0.4), by: 3) {
                for x in stride(from: 0, to: Int(w), by: 3) {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let shade = 0.35 + Double(seed >> 24) / 255 * 0.15
                    context.setFillColor(CGColor(red: shade, green: shade * 0.85, blue: shade * 0.6, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 3, height: 3))
                }
            }
            // A figure: body and head.
            context.setFillColor(CGColor(red: 0.12, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: w * 0.44, y: h * 0.2, width: w * 0.12, height: h * 0.45))
            context.fillEllipse(in: CGRect(x: w * 0.455, y: h * 0.64, width: w * 0.09, height: w * 0.09))
        }
    }

    static func draw(width: Int, height: Int, in folder: URL, name: String, _ body: (CGContext, Double, Double) -> Void) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        body(context, Double(width), Double(height))
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kinora-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.serialized) struct LivingPhotoGeneratorTests {
    @Test func makesASeamlessLoopOfTheRightShape() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try SyntheticPhoto.figure(in: folder)
        let before = try Data(contentsOf: photo)
        let result = try await LivingPhotoGenerator.generate(photo: photo, output: CGSize(width: 480, height: 300), seconds: 2,
                                                             framesPerSecond: 15, workFolder: folder)
        print("living photo 480x300 2 s: subjects \(result.detection.count) lifted \(result.detection.lifted) failure \(result.detection.failure ?? "-"), prepare \(String(format: "%.2f", result.prepareSeconds)) s, encode \(String(format: "%.2f", result.encodeSeconds)) s, \(result.codec), \(result.bytes) bytes")
        #expect(FileManager.default.fileExists(atPath: result.video.path))
        #expect(FileManager.default.fileExists(atPath: result.thumbnail.path))
        #expect(result.bytes > 0)
        #expect(["hevc", "h264"].contains(result.codec))
        // The original photo is only read.
        #expect(try Data(contentsOf: photo) == before)

        let asset = AVURLAsset(url: result.video)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 2) < 0.01)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 480, height: 300))
        let frames = try await countFrames(asset)
        #expect(frames == 30)
    }

    @Test func theLastFrameLeadsBackToTheFirst() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let renderer = try LivingPhotoRenderer(photo: try SyntheticPhoto.figure(in: folder), output: CGSize(width: 320, height: 200))
        let start = try #require(renderer.image(at: 0)), wrapped = try #require(renderer.image(at: 1))
        #expect(pixels(start) == pixels(wrapped))
        // And the loop does move: a quarter of the way through differs from the start.
        let quarter = try #require(renderer.image(at: 0.25))
        #expect(pixels(start) != pixels(quarter))
        #expect(start.width == 320 && start.height == 200)
    }

    @Test func cancellingRemovesEverythingItWrote() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try SyntheticPhoto.figure(in: folder)
        let started = Started()
        let task = Task {
            try await LivingPhotoGenerator.generate(photo: photo, output: CGSize(width: 640, height: 400), seconds: 20,
                                                    framesPerSecond: 30, workFolder: folder) { value in
                if value > 0.2 { started.mark() }
            }
        }
        // Wait until frames are being written, then cancel.
        for _ in 0..<600 where !started.value { try await Task.sleep(for: .milliseconds(50)) }
        task.cancel()
        await #expect(throws: LivingPhotoError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("living.mov").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("thumbnail.png").path))
    }

    @Test func refusesFilesThatAreNotPhotos() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("notes.png")
        try Data("not a photo".utf8).write(to: text)
        await #expect(throws: LivingPhotoError.unreadablePhoto) {
            try await LivingPhotoGenerator.generate(photo: text, output: CGSize(width: 320, height: 200), workFolder: folder)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("living.mov").path))
    }

    @Test func aPhotoWithoutASubjectDriftsAsOneLayer() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = try SyntheticPhoto.draw(width: 800, height: 600, in: folder, name: "plain.png") { context, w, h in
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let renderer = try LivingPhotoRenderer(photo: plain, output: CGSize(width: 320, height: 200))
        #expect(!renderer.detection.lifted)
        #expect(renderer.plan.subject == nil)
        #expect(renderer.image(at: 0.5) != nil)
    }

    /// The cost on the machine running the tests, at a real display size. Set KINORA_BENCH=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINORA_BENCH"] == "1"))
    func benchmarkAFullSizeLoop() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try SyntheticPhoto.figure(width: 4032, height: 3024, in: folder)
        let wall = Date()
        let result = try await LivingPhotoGenerator.generate(photo: photo, output: CGSize(width: 2940, height: 1912), workFolder: folder)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("""
        BENCH living photo 4032x3024 -> 2940x1912, 12 s at 30 fps: \
        prepare \(String(format: "%.2f", result.prepareSeconds)) s, encode \(String(format: "%.2f", result.encodeSeconds)) s, \
        wall \(String(format: "%.2f", Date().timeIntervalSince(wall))) s, \(result.codec), \
        \(String(format: "%.1f", Double(result.bytes) / 1_000_000)) MB, peak RSS \(usage.ru_maxrss / 1_048_576) MB, \
        subjects \(result.detection.count), lifted \(result.detection.lifted), detection failure \(result.detection.failure ?? "-")
        """)
        #expect(result.bytes > 0)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private func countFrames(_ asset: AVURLAsset) async throws -> Int {
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 }
        }
        return count
    }
}

/// Set from the generator's background thread, read by the test.
final class Started: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func mark() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
