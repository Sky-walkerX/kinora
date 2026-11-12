// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import Foundation

/// How much of a display's desktop windows hide. macOS does not tell a wallpaper plug-in when
/// windows cover it, so Kinora works it out from the window list (bounds need no permission).
public enum DesktopCoverage {
    /// The fraction of `display` covered by the union of `windows`, 0...1. Overlaps count once.
    public static func coveredFraction(of display: CGRect, by windows: [CGRect]) -> Double {
        guard display.width > 0, display.height > 0 else { return 0 }
        let rects = windows.map { $0.intersection(display) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !rects.isEmpty else { return 0 }
        // Sweep across x: between consecutive edges, the covered height is the union of the
        // y-intervals of the windows spanning that strip.
        let xs = Array(Set(rects.flatMap { [$0.minX, $0.maxX] })).sorted()
        var area = 0.0
        for (left, right) in zip(xs, xs.dropFirst()) where right > left {
            let spans = rects.filter { $0.minX <= left && $0.maxX >= right }.map { ($0.minY, $0.maxY) }.sorted { $0.0 < $1.0 }
            var covered = 0.0, start = -Double.infinity, end = -Double.infinity
            for (lo, hi) in spans {
                if lo > end { covered += end - start > 0 ? end - start : 0; start = lo; end = hi } else { end = max(end, hi) }
            }
            covered += end - start > 0 ? end - start : 0
            area += covered * (right - left)
        }
        return min(1, area / (display.width * display.height))
    }

    /// The window rectangles that hide the desktop, from `CGWindowListCopyWindowInfo` entries:
    /// ordinary on-screen windows (layer 0) that are not fully transparent.
    public static func occludingRects(from windowList: [[String: Any]]) -> [CGRect] {
        windowList.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return rect
        }
    }
}
