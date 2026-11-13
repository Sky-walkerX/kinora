// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import Foundation

/// How much a Living Photo moves. `subtle` is the motion the spike settled on after the owner
/// asked for less (docs/spikes/2026-11-12-living-photos-spike.md, round 2).
public enum LivingPhotoMotion: String, Codable, CaseIterable, Sendable {
    case gentle, subtle, lively

    /// Multiplier on the spike's round-2 motion.
    public var strength: Double {
        switch self {
        case .gentle: 0.6
        case .subtle: 1.0
        case .lively: 1.4
        }
    }

    public var title: String {
        switch self {
        case .gentle: "Gentle"
        case .subtle: "Subtle"
        case .lively: "Lively"
        }
    }
}

/// Where one layer of a Living Photo sits at a moment of the loop: scaled about the crop's
/// centre, then moved, in canvas pixels with y pointing up (Core Image's convention).
public struct LayerPlacement: Equatable, Sendable {
    public var dx: Double
    public var dy: Double
    public var scale: Double

    /// Where a canvas point ends up.
    public func apply(_ point: CGPoint, about center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (point.x - center.x) * scale + dx, y: center.y + (point.y - center.y) * scale + dy)
    }

    /// Where a canvas rectangle ends up.
    public func apply(_ rect: CGRect, about center: CGPoint) -> CGRect {
        let a = apply(CGPoint(x: rect.minX, y: rect.minY), about: center)
        let b = apply(CGPoint(x: rect.maxX, y: rect.maxY), about: center)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

/// Everything about a Living Photo that is arithmetic: the canvas the photo is scaled to, the
/// crop that frames its subject, how each layer moves through the loop, and how the gap behind
/// the subject is filled. The renderer only follows it, so it can be tested without a GPU.
public struct LivingPhotoPlan: Equatable, Sendable {
    /// The photo covers the output plus this much, so motion never shows an edge.
    public static let overscan = 1.08
    /// The crop keeps this fraction of the canvas between itself and the canvas's edge.
    public static let edgeMargin = 0.02
    /// Room above the subject's top, as a fraction of the output's height.
    public static let headroom = 0.08

    /// Output size in pixels, even on both sides.
    public var output: CGSize
    /// The photo, scaled to cover `output` with overscan, in pixels.
    public var canvas: CGSize
    /// Photo pixels to canvas pixels.
    public var photoScale: Double
    /// The crop's centre on the canvas.
    public var center: CGPoint
    /// The subject's bounds on the canvas, if there is one.
    public var subject: CGRect?
    public var motion: LivingPhotoMotion
    public var seconds: Double
    public var framesPerSecond: Int

    public var frameCount: Int { max(2, Int((seconds * Double(framesPerSecond)).rounded())) }

    /// The crop on the canvas.
    public var crop: CGRect {
        CGRect(x: center.x - output.width / 2, y: center.y - output.height / 2, width: output.width, height: output.height)
    }

    /// A plan for a photo of `photo` pixels shown at `output` pixels. `subject` is in photo
    /// pixels, y up, when the photo has one.
    public static func make(photo: CGSize, output requested: CGSize, subject photoSubject: CGRect?,
                            motion: LivingPhotoMotion = .subtle, seconds: Double = 12, framesPerSecond: Int = 30) -> LivingPhotoPlan? {
        guard photo.width >= 1, photo.height >= 1, requested.width >= 2, requested.height >= 2,
              photo.width.isFinite, photo.height.isFinite, requested.width.isFinite, requested.height.isFinite else { return nil }
        func even(_ value: Double) -> Double { max(2, (value / 2).rounded(.down) * 2) }
        let output = CGSize(width: even(requested.width), height: even(requested.height))
        let scale = max(output.width * overscan / photo.width, output.height * overscan / photo.height)
        let canvas = CGSize(width: (photo.width * scale).rounded(.up), height: (photo.height * scale).rounded(.up))
        let subject = photoSubject.flatMap { rect -> CGRect? in
            let clipped = rect.intersection(CGRect(origin: .zero, size: photo))
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            return CGRect(x: clipped.minX * scale, y: clipped.minY * scale, width: clipped.width * scale, height: clipped.height * scale)
        }
        let center = framing(canvas: canvas, output: output, subject: subject)
        return LivingPhotoPlan(output: output, canvas: canvas, photoScale: scale, center: center, subject: subject, motion: motion,
                               seconds: max(2, min(60, seconds)), framesPerSecond: max(10, min(60, framesPerSecond)))
    }

    /// The crop's centre: on the subject, keeping its top in view with headroom, inside the canvas.
    ///
    /// A subject taller than the crop allows is aligned by its top, as in the spike, so a
    /// person's head stays in. A smaller one is centred, so it is not pinned to the top edge.
    static func framing(canvas: CGSize, output: CGSize, subject: CGRect?) -> CGPoint {
        var cx = canvas.width / 2, cy = canvas.height / 2
        if let subject {
            let topAligned = subject.maxY + output.height * headroom - output.height / 2
            cy = max(subject.midY, topAligned)
            cx = subject.midX
        }
        func clamp(_ value: Double, _ half: Double, _ extent: Double) -> Double {
            let margin = extent * edgeMargin
            let low = half + margin, high = extent - half - margin
            return low <= high ? min(max(value, low), high) : extent / 2
        }
        return CGPoint(x: clamp(cx, output.width / 2, canvas.width), y: clamp(cy, output.height / 2, canvas.height))
    }

    // MARK: - Motion

    /// The subject's sideways sway, as a fraction of the output's width (spike round 2).
    static let sway = 0.0075
    /// Vertical sway, as a fraction of the output's height.
    static let lift = 0.004
    /// The background moves this fraction of the subject's motion, which reads as depth.
    static let backgroundRatio = 0.45
    static let subjectZoom = 0.011
    static let backgroundZoom = 0.006
    /// A photo with no subject drifts as one layer, a little more so the motion still shows.
    static let soloSway = 0.012
    static let soloLift = 0.006
    static let soloZoom = 0.008

    /// The loop's phase for frame `index`: frame `frameCount` would be frame 0 again.
    public func phase(ofFrame index: Int) -> Double { Double(index) / Double(frameCount) }

    /// The subject layer at phase `t` in [0, 1). sin(2πt) and sin(4πt) both come back to where
    /// they started at t = 1, so the loop has no seam: a figure-eight with a slight zoom.
    public func subjectPlacement(at t: Double) -> LayerPlacement {
        let a = 2 * Double.pi * t, k = motion.strength
        return LayerPlacement(dx: k * Self.sway * output.width * sin(a), dy: k * Self.lift * output.height * sin(2 * a),
                              scale: 1 + k * Self.subjectZoom * sin(a))
    }

    /// The background layer at phase `t`: less motion than the subject, or the whole photo's
    /// drift when there is no subject.
    public func backgroundPlacement(at t: Double) -> LayerPlacement {
        let a = 2 * Double.pi * t, k = motion.strength
        guard subject != nil else {
            return LayerPlacement(dx: k * Self.soloSway * output.width * sin(a), dy: k * Self.soloLift * output.height * sin(2 * a),
                                  scale: 1 + k * Self.soloZoom * (0.5 + 0.5 * sin(a)))
        }
        let s = subjectPlacement(at: t)
        return LayerPlacement(dx: Self.backgroundRatio * s.dx, dy: Self.backgroundRatio * s.dy, scale: 1 + k * Self.backgroundZoom * sin(a))
    }

    /// True when the background covers the whole crop at phase `t`, so no edge can show.
    public func backgroundCoversCrop(at t: Double) -> Bool {
        let placed = backgroundPlacement(at: t).apply(CGRect(origin: .zero, size: canvas), about: center)
        let crop = crop, slack = 0.5
        return placed.minX <= crop.minX + slack && placed.minY <= crop.minY + slack
            && placed.maxX >= crop.maxX - slack && placed.maxY >= crop.maxY - slack
    }

    /// The furthest the subject moves against the background over the loop, in canvas pixels.
    /// The filled gap behind it must be at least this wide, or the photo's own subject pixels
    /// would show through as a ghost.
    public func largestSubjectShift(samples: Int = 240) -> Double {
        guard let subject else { return 0 }
        let corners = [CGPoint(x: subject.minX, y: subject.minY), CGPoint(x: subject.maxX, y: subject.minY),
                       CGPoint(x: subject.minX, y: subject.maxY), CGPoint(x: subject.maxX, y: subject.maxY)]
        var largest = 0.0
        for step in 0..<samples {
            let t = Double(step) / Double(samples)
            let fg = subjectPlacement(at: t), bg = backgroundPlacement(at: t)
            for corner in corners {
                let a = fg.apply(corner, about: center), b = bg.apply(corner, about: center)
                largest = max(largest, hypot(a.x - b.x, a.y - b.y))
            }
        }
        return largest
    }

    // MARK: - Gap filling

    /// Sizes for lifting the subject and filling the gap behind it, in canvas pixels. They
    /// scale with the canvas, so a small preview looks like the full render.
    public struct Fill: Equatable, Sendable {
        /// The subject's edge is pulled in by this much, so it carries none of the background.
        public var edgeInset: Double
        public var edgeSoftness: Double
        /// The gap excludes every subject pixel: the mask grown by this much, then thresholded.
        public var gapGrowth: Double
        /// Sideways blur radii for the fill, widest first; nearer pixels win where they reach.
        public var fillRadii: [Double]
        /// Softens row-to-row streaks the sideways blur leaves.
        public var streakSoftness: Double
        /// Fine detail is the photo minus a blur of this size.
        public var detailSoftness: Double
        /// The textured fill blends into the photo across this much.
        public var seamSoftness: Double
    }

    /// A subject mask is worth lifting when it covers between 0.2% and 85% of the photo. Less is
    /// noise; more leaves too little background to fill the gap from.
    public static func isUsableSubject(coverage: Double) -> Bool { coverage >= 0.002 && coverage <= 0.85 }

    public var fill: Fill {
        let w = canvas.width
        // The spike's absolute pixel sizes were tuned on a 3176-pixel-wide canvas.
        let px = w / 3176
        // The spike grew the gap by 1% of the width. A tall canvas, a large subject or more
        // motion can move the subject further than that, so the gap grows with the motion.
        let gap = max(w * 0.010, largestSubjectShift(samples: 96) * 1.2)
        return Fill(edgeInset: max(0.5, 2 * px), edgeSoftness: max(0.5, 1.5 * px), gapGrowth: gap,
                    fillRadii: [w * 0.05 * 2.5, w * 0.015 * 2.5, w * 0.006 * 2.5], streakSoftness: w * 0.002,
                    detailSoftness: max(0.75, 2.5 * px), seamSoftness: max(1, 3 * px))
    }
}
