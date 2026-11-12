// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import Foundation

/// How Kinora stores an imported video: once, as HEVC, at the size the user's displays need.
/// A 4K clip on a 1440p display wastes disk and decoding energy on pixels nobody sees.
public enum VideoOptimization {
    /// The largest side Kinora stores, whatever the display.
    public static let maxSide = 3840.0

    /// The size that covers `display` with the source's aspect ratio. Never larger than the
    /// source, never above `maxSide`, and even on both sides as HEVC needs.
    public static func targetSize(source: CGSize, display: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .zero }
        var scale = 1.0
        if display.width > 0, display.height > 0 {
            scale = min(1, max(display.width / source.width, display.height / source.height))
        }
        scale = min(scale, maxSide / max(source.width, source.height))
        func even(_ value: Double) -> Double { max(2, (value / 2).rounded() * 2) }
        return CGSize(width: even(source.width * scale), height: even(source.height * scale))
    }

    /// An HEVC bitrate that keeps slow, detailed wallpaper footage clean: about 0.06 bits per
    /// pixel per frame, with frames above 30 a second costing less each, between 2 and 20 Mbit/s.
    public static func bitrate(width: Double, height: Double, framesPerSecond: Double) -> Int {
        let fps = min(60, max(1, framesPerSecond))
        let effectiveFrames = fps <= 30 ? fps : 30 + (fps - 30) * 0.5
        let bits = width * height * effectiveFrames * 0.06
        return Int(min(20_000_000, max(2_000_000, bits)))
    }

    /// Bytes the optimized video will take, roughly.
    public static func estimatedBytes(bitrate: Int, duration: TimeInterval) -> Int64 {
        Int64(Double(bitrate) / 8 * max(0, duration))
    }

    /// Kinora keeps whichever file is smaller; converting only pays when it saves a tenth or more.
    public static func keepsOptimized(originalBytes: Int64, optimizedBytes: Int64) -> Bool {
        optimizedBytes > 0 && Double(optimizedBytes) <= Double(originalBytes) * 0.9
    }
}
