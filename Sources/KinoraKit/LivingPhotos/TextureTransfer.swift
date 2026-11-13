// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// Gives the smooth fill behind a lifted subject the photo's own fine texture, so the revealed
/// gap reads as ground or foliage rather than a smear (spike round 2).
///
/// The detail (photo minus a slight blur) is copied from beside the gap as one coherent block:
/// the left half of the gap from its left, the right half from its right, with the seam between
/// them feathered. Copying a block, rather than single pixels, keeps the grain's structure.
public enum TextureTransfer {
    public struct Failure: Error, Equatable {}

    /// Adds detail to `fill` inside the gap, in place. All buffers are RGBA8, `width` × `height`,
    /// rows top to bottom. `gap` marks the pixels to texture. `isCancelled` is checked every row.
    /// Returns false when cancelled, leaving `fill` partly textured.
    @discardableResult
    public static func apply(photo: [UInt8], blurred: [UInt8], fill: inout [UInt8], gap: [Bool], width: Int, height: Int,
                             isCancelled: () -> Bool = { false }) throws -> Bool {
        let pixels = width * height
        guard width > 0, height > 0, photo.count == pixels * 4, blurred.count == pixels * 4, fill.count == pixels * 4,
              gap.count == pixels else { throw Failure() }
        guard let columns = gapColumns(gap, width: width, height: height) else { return true }
        let span = columns.upperBound - columns.lowerBound + 1
        let seam = (columns.lowerBound + columns.upperBound) / 2
        let feather = max(8, span / 10)
        let spacing = 4

        for y in 0..<height {
            if isCancelled() { return false }
            let row = y * width
            for x in columns where gap[row + x] {
                let left = x - span - spacing, right = x + span + spacing
                // Weight of the left source: 1 well left of the seam, 0 well right, a ramp across it.
                let t = min(1, max(0, Double(seam + feather - x) / Double(2 * feather)))
                let leftOK = left >= 0 && !gap[row + left]
                let rightOK = right < width && !gap[row + right]
                guard leftOK || rightOK else { continue }
                let target = (row + x) * 4
                for channel in 0..<3 {
                    let l = leftOK ? Double(Int(photo[(row + left) * 4 + channel]) - Int(blurred[(row + left) * 4 + channel])) : 0
                    let r = rightOK ? Double(Int(photo[(row + right) * 4 + channel]) - Int(blurred[(row + right) * 4 + channel])) : 0
                    let detail: Double = leftOK && rightOK ? t * l + (1 - t) * r : (leftOK ? l : r)
                    fill[target + channel] = UInt8(max(0, min(255, (Double(fill[target + channel]) + detail).rounded())))
                }
            }
        }
        return true
    }

    /// The leftmost and rightmost columns that hold any gap pixel; nil when there is no gap.
    public static func gapColumns(_ gap: [Bool], width: Int, height: Int) -> ClosedRange<Int>? {
        var minX = width, maxX = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where gap[row + x] {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        return maxX >= minX ? minX...maxX : nil
    }
}
