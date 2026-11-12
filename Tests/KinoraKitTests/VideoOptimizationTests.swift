// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import Testing
@testable import KinoraKit

@Suite struct VideoOptimizationTests {
    let macBookAir = CGSize(width: 2940, height: 1912)

    @Test func shrinksA4KClipToCoverTheDisplay() {
        let size = VideoOptimization.targetSize(source: CGSize(width: 3840, height: 2160), display: macBookAir)
        // Height decides: 2160 scaled to 1912 keeps 16:9 and still covers 2940 wide.
        #expect(size == CGSize(width: 3400, height: 1912))
        #expect(size.width >= macBookAir.width && size.height >= macBookAir.height)
    }

    @Test func neverUpscales() {
        #expect(VideoOptimization.targetSize(source: CGSize(width: 1920, height: 1080), display: macBookAir) == CGSize(width: 1920, height: 1080))
    }

    @Test func capsHugeSourcesAtThe4KLimit() {
        let size = VideoOptimization.targetSize(source: CGSize(width: 7680, height: 4320), display: CGSize(width: 6016, height: 3384))
        #expect(size.width == 3840)
        #expect(size.height == 2160)
    }

    @Test func keepsSidesEven() {
        let size = VideoOptimization.targetSize(source: CGSize(width: 3001, height: 1999), display: CGSize(width: 1501, height: 999))
        #expect(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0)
    }

    @Test func handlesMissingSizes() {
        #expect(VideoOptimization.targetSize(source: .zero, display: macBookAir) == .zero)
        #expect(VideoOptimization.targetSize(source: CGSize(width: 1920, height: 1080), display: .zero) == CGSize(width: 1920, height: 1080))
    }

    @Test func bitrateScalesWithPixelsAndStaysInBounds() {
        let fourK30 = VideoOptimization.bitrate(width: 3840, height: 2160, framesPerSecond: 30)
        let tenEighty30 = VideoOptimization.bitrate(width: 1920, height: 1080, framesPerSecond: 30)
        #expect(fourK30 > tenEighty30)
        #expect(VideoOptimization.bitrate(width: 3840, height: 2160, framesPerSecond: 60) <= 20_000_000)
        #expect(VideoOptimization.bitrate(width: 320, height: 240, framesPerSecond: 24) == 2_000_000)
        // Frames above 30 a second cost half as much each.
        #expect(VideoOptimization.bitrate(width: 1920, height: 1080, framesPerSecond: 60) < 2 * tenEighty30)
    }

    @Test func keepsTheOptimizedFileOnlyWhenItSavesEnough() {
        #expect(VideoOptimization.keepsOptimized(originalBytes: 100, optimizedBytes: 90))
        #expect(!VideoOptimization.keepsOptimized(originalBytes: 100, optimizedBytes: 95))
        #expect(!VideoOptimization.keepsOptimized(originalBytes: 100, optimizedBytes: 0))
    }
}
