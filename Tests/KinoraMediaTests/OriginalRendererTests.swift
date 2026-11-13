// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import Foundation
import KinoraKit
import IOSurface
import Metal
import Testing
@testable import KinoraRender

@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct OriginalRendererTests {
    @Test func everyOriginalCompilesAndDraws() throws {
        let renderer = try OriginalRenderer()
        for original in KinoraOriginals.all {
            _ = try renderer.pipeline(for: original)
            let image = try renderer.image(original, width: 320, height: 200, time: 30, sky: .afternoon)
            #expect(image.width == 320 && image.height == 200)
            // Not a flat colour: every original has visible structure.
            #expect(distinctColours(image) > 16, "\(original.slug) drew a flat image")
        }
    }

    @Test func theLiveSkyChangesWithTheSun() throws {
        let renderer = try OriginalRenderer()
        let sky = try #require(KinoraOriginals.all.first { $0.usesSun })
        let day = try renderer.image(sky, width: 160, height: 100, time: 10, sky: .afternoon)
        let night = try renderer.image(sky, width: 160, height: 100, time: 10, sky: SkySample(elevation: -30, azimuth: 0, daylight: 0, offset: 0))
        #expect(brightness(day) > brightness(night) * 2)
    }

    @Test func motionMovesAndTimeIsDeterministic() throws {
        let renderer = try OriginalRenderer()
        for original in KinoraOriginals.all {
            let a = try renderer.image(original, width: 160, height: 100, time: 100, sky: .afternoon)
            let b = try renderer.image(original, width: 160, height: 100, time: 100, sky: .afternoon)
            let c = try renderer.image(original, width: 160, height: 100, time: 160, sky: .afternoon)
            // Only the dither differs between identical frames; a minute later the picture has moved.
            #expect(difference(a, b) < difference(a, c), "\(original.slug) does not move")
        }
    }

    @Test func snapshotsAreTheRequestedSize() throws {
        let renderer = try OriginalRenderer()
        let surface = try renderer.surface(KinoraOriginals.all[0], width: 1470, height: 956, time: 0, sky: .afternoon)
        #expect(IOSurfaceGetWidth(surface) == 1470 && IOSurfaceGetHeight(surface) == 956)
    }

    /// GPU time per frame at the size each original draws on a 2940 × 1912 display. Printed for
    /// the record; the runner's GPU is virtual, so this is not a real Mac's cost.
    @Test func benchmarkGPUCostPerFrame() throws {
        let renderer = try OriginalRenderer()
        for original in KinoraOriginals.all {
            let size = KinoraOriginals.drawableSize(for: original, width: 2940, height: 1912)
            if let ms = try renderer.measure(original, width: size.width, height: size.height, frames: 30) {
                let busy = ms * Double(original.framesPerSecond) / 10
                print("BENCH original \(original.slug) \(size.width)x\(size.height) at \(original.framesPerSecond) fps: \(String(format: "%.2f", ms)) ms GPU per frame, \(String(format: "%.1f", busy))% of the GPU's time")
            } else {
                print("BENCH original \(original.slug): this GPU reports no timestamps")
            }
        }
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private func distinctColours(_ image: CGImage) -> Int {
        let data = rgba(image)
        var colours = Set<UInt32>()
        for i in stride(from: 0, to: data.count, by: 4) {
            colours.insert(UInt32(data[i] >> 3) << 10 | UInt32(data[i + 1] >> 3) << 5 | UInt32(data[i + 2] >> 3))
        }
        return colours.count
    }

    private func brightness(_ image: CGImage) -> Double {
        let data = rgba(image)
        var total = 0.0
        for i in stride(from: 0, to: data.count, by: 4) { total += Double(data[i]) + Double(data[i + 1]) + Double(data[i + 2]) }
        return total / Double(data.count / 4)
    }

    private func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let x = rgba(a), y = rgba(b)
        var total = 0.0
        for i in 0..<min(x.count, y.count) { total += abs(Double(x[i]) - Double(y[i])) }
        return total / Double(x.count)
    }
}
