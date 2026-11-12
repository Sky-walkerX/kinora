// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// What a Kinora choice in the wallpaper store points at. macOS stores these bytes and hands
/// them back on every acquire, so they must stay small and readable by every later version.
public struct ChoiceConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// The library item shown on the desktop.
    public var wallpaper: UUID
    /// The library item shown on the Lock Screen, when it differs from the desktop's.
    public var lockScreen: UUID?

    public init(wallpaper: UUID, lockScreen: UUID? = nil) {
        self.version = Self.currentVersion
        self.wallpaper = wallpaper
        self.lockScreen = lockScreen
    }

    /// The item to draw for a presentation mode.
    public func item(for mode: PresentationMode) -> UUID {
        mode == .locked ? (lockScreen ?? wallpaper) : wallpaper
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a plain struct of UUIDs and an Int cannot fail.
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Nil for bytes Kinora did not write, such as another plug-in's configuration.
    public static func decode(_ data: Data?) -> ChoiceConfiguration? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ChoiceConfiguration.self, from: data)
    }
}
