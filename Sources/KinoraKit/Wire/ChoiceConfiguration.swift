// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// What a Kinora choice in the wallpaper store says. macOS stores these bytes and hands them
/// back on every acquire, so they must stay small and readable by every later version.
///
/// A choice made with "Use as Wallpaper" follows Kinora's live selection, so later changes need
/// no store write and no WallpaperAgent restart; `wallpaper` is then only the fallback. A tile
/// picked in System Settings names one wallpaper and does not follow.
public struct ChoiceConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    /// The desktop's item, or the fallback when following Kinora.
    public var wallpaper: UUID
    /// The Lock Screen's item, when it differs (version 1 choices).
    public var lockScreen: UUID?
    /// True when the surface follows Kinora's `selection.json` instead of these fields.
    public var followsKinora: Bool?

    public init(wallpaper: UUID, lockScreen: UUID? = nil, followsKinora: Bool = false) {
        self.version = Self.currentVersion
        self.wallpaper = wallpaper
        self.lockScreen = lockScreen
        self.followsKinora = followsKinora ? true : nil
    }

    public var follows: Bool { followsKinora == true }

    /// The rules to apply: Kinora's selection when following it, else this choice's own fields.
    public func rules(selection: KinoraSelection?) -> WallpaperRules {
        if follows, let selection { return selection.rules }
        return WallpaperRules(wallpaper: wallpaper, lockScreen: lockScreen)
    }

    /// The item to draw for a presentation mode, ignoring any live selection.
    public func item(for mode: PresentationMode) -> UUID {
        mode == .locked ? (lockScreen ?? wallpaper) : wallpaper
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a plain struct of UUIDs, an Int and a Bool cannot fail.
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Nil for bytes Kinora did not write, such as another plug-in's configuration.
    public static func decode(_ data: Data?) -> ChoiceConfiguration? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ChoiceConfiguration.self, from: data)
    }
}
