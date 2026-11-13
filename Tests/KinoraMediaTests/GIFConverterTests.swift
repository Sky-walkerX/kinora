// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KinoraMedia

@Suite struct GIFConverterTests {
    /// An animated GIF drawn by the test: a square moving across five frames, 0.1 s each.
    func makeGIF(frames: Int, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("moving.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<frames {
            let context = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 10 + index * 20, y: 30, width: 20, height: 20))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func convertsAnAnimatedGIFToAVideoWithItsTiming() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gif = try makeGIF(frames: 5, in: folder)
        let video = folder.appendingPathComponent("moving.mov")
        try GIFConverter.convert(gif, to: video)
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 0.5) < 0.02)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 120, height: 80))
    }

    @Test func aStillGIFIsNotAnimated() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gif = try makeGIF(frames: 1, in: folder)
        #expect(throws: GIFConverter.Failure.notAnimated) { try GIFConverter.convert(gif, to: folder.appendingPathComponent("x.mov")) }
    }
}
