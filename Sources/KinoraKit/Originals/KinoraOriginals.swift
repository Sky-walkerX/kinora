// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// One of Kinora's own generative wallpapers: a Metal shader drawn live in the plug-in. They
/// are built in, need no download and never loop visibly.
public struct KinoraOriginal: Identifiable, Equatable, Sendable {
    /// A fixed identifier, so rules, store choices and System Settings tiles can name it like a
    /// library item. Never change one after release.
    public var id: UUID
    /// The shader's fragment function and the thumbnail's file stem.
    public var slug: String
    public var name: String
    public var summary: String
    /// The frame rate it looks right at; the user's cap can lower it further.
    public var framesPerSecond: Int
    /// The fraction of the display's pixels it draws, scaled up by the compositor. Soft,
    /// slow scenes look the same at a fraction of the cost.
    public var renderScale: Double
    /// Three colours the shader mixes, as linear-ish RGB in 0...1.
    public var palette: [SIMD3<Float>]
    /// Follows the real sun where the Mac is.
    public var usesSun: Bool

    /// The thumbnail's file name in the library's thumbnails folder.
    public var thumbnailName: String { "original-\(slug).png" }

    /// The original as a library item, so it can sit in grids, playlists and pickers. It is
    /// never written to the library's index.
    public var libraryItem: LibraryItem {
        var item = LibraryItem(id: id, name: name, kind: .original, media: slug, thumbnail: thumbnailName,
                               addedAt: Date(timeIntervalSince1970: 1_793_491_200))
        item.attribution = LibraryItem.Attribution(author: "The Kinora Contributors", license: "GPL-3.0-or-later")
        return item
    }
}

/// The built-in set: few, and polished.
public enum KinoraOriginals {
    public static let all: [KinoraOriginal] = [
        KinoraOriginal(id: UUID(uuidString: "6B1F7E2A-4C3D-4E8A-9A51-0D2C7B3E5A01")!, slug: "liveSky", name: "Live Sky",
                       summary: "The sky outside, following the real sun from dawn to night, with slow clouds.",
                       framesPerSecond: 20, renderScale: 0.5,
                       palette: [SIMD3(0.30, 0.52, 0.86), SIMD3(0.98, 0.62, 0.36), SIMD3(0.04, 0.05, 0.12)], usesSun: true),
        KinoraOriginal(id: UUID(uuidString: "6B1F7E2A-4C3D-4E8A-9A51-0D2C7B3E5A02")!, slug: "aurora", name: "Aurora",
                       summary: "Northern lights folding slowly over a starry sky.",
                       framesPerSecond: 24, renderScale: 0.45,
                       palette: [SIMD3(0.18, 0.95, 0.62), SIMD3(0.45, 0.30, 0.95), SIMD3(0.02, 0.03, 0.08)], usesSun: false),
        KinoraOriginal(id: UUID(uuidString: "6B1F7E2A-4C3D-4E8A-9A51-0D2C7B3E5A03")!, slug: "tide", name: "Tide",
                       summary: "Soft colour fields drifting into one another, like light on water.",
                       framesPerSecond: 15, renderScale: 0.25,
                       palette: [SIMD3(0.10, 0.36, 0.62), SIMD3(0.36, 0.74, 0.78), SIMD3(0.92, 0.80, 0.62)], usesSun: false),
        KinoraOriginal(id: UUID(uuidString: "6B1F7E2A-4C3D-4E8A-9A51-0D2C7B3E5A04")!, slug: "lava", name: "Lava Lamp",
                       summary: "Warm wax rising and falling, merging and parting.",
                       framesPerSecond: 24, renderScale: 0.5,
                       palette: [SIMD3(0.98, 0.42, 0.18), SIMD3(0.95, 0.15, 0.35), SIMD3(0.10, 0.03, 0.10)], usesSun: false),
    ]

    public static func original(_ id: UUID?) -> KinoraOriginal? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    public static func isOriginal(_ id: UUID) -> Bool { original(id) != nil }

    /// The frame rate to draw at: the original's own, capped by the user's setting and, on
    /// battery, by the battery cap.
    public static func framesPerSecond(for original: KinoraOriginal, settings: PlaybackSettings, cap: Int?) -> Int {
        var rate = min(original.framesPerSecond, settings.generativeFrameRate)
        if let cap { rate = min(rate, cap) }
        return max(1, rate)
    }

    /// The drawable's size in pixels for a surface `width` × `height` pixels.
    public static func drawableSize(for original: KinoraOriginal, width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1, max(0.1, original.renderScale))
        return (max(16, Int((Double(width) * scale).rounded())), max(16, Int((Double(height) * scale).rounded())))
    }
}
