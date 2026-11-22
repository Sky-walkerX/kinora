// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
#if canImport(ColorSync)
import ColorSync
import CoreGraphics
#endif

/// A wallpaper for one display. Every surface on that display, desktop and Lock Screen, shows
/// it instead of the selection's main rules. The plug-in tells displays apart by the
/// `directDisplayID` WallpaperAgent sends with each surface, so a choice needs no store write
/// and no WallpaperAgent restart: it lives in `selection.json` like the rest of the rules.
///
/// A display's choice is fixed: rotations, schedules and Dark Mode variants belong to the main
/// rules, and the displays without a choice of their own.
public struct DisplayChoice: Codable, Equatable, Sendable {
    /// The display's desktop item.
    public var wallpaper: UUID
    /// The display's Lock Screen item. Nil follows the main rules' Lock Screen when they have
    /// one, and this display's wallpaper otherwise.
    public var lockScreen: UUID?
    /// The display's name when the choice was made, to show while it is disconnected.
    public var name: String?

    public init(wallpaper: UUID, lockScreen: UUID? = nil, name: String? = nil) {
        self.wallpaper = wallpaper
        self.lockScreen = lockScreen
        self.name = name.map { String($0.prefix(Self.maxNameLength)) }
    }

    /// Display names come from the display's own data; keep a damaged one from bloating the UI.
    public static let maxNameLength = 80

    /// The rules this display follows, given the selection's main rules.
    public func rules(main: WallpaperRules) -> WallpaperRules {
        WallpaperRules(wallpaper: wallpaper, lockScreen: lockScreen ?? main.lockScreen)
    }

    /// Every item the choice can show.
    public var allItems: Set<UUID> {
        var items: Set<UUID> = [wallpaper]
        if let lockScreen { items.insert(lockScreen) }
        return items
    }

    #if canImport(ColorSync)
    /// A display's lasting identity: its UUID, which survives reboots and reconnection, unlike
    /// the `CGDirectDisplayID` WallpaperAgent sends. Nil when macOS can't say, in which case the
    /// surface shows the main rules.
    public static func key(for display: CGDirectDisplayID) -> String? {
        guard display != 0, let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else { return nil }
        return string as String
    }
    #endif
}

extension KinoraSelection {
    /// The rules a surface on `display` follows: the display's own choice, else the main rules.
    public func rules(forDisplay display: String?) -> WallpaperRules {
        guard let display, let choice = displays?[display] else { return rules }
        return choice.rules(main: rules)
    }

    /// Every item the selection can show, on any display.
    public var allItems: Set<UUID> {
        var items = rules.allItems
        for choice in (displays ?? [:]).values { items.formUnion(choice.allItems) }
        return items
    }

    /// Where `id` appears: the main rules' places, then `.display` when a display uses it.
    public func uses(of id: UUID) -> [RuleUse] {
        var uses = rules.uses(of: id)
        if (displays ?? [:]).values.contains(where: { $0.allItems.contains(id) }) { uses.append(.display) }
        return uses
    }

    /// The selection with `display`'s choice set, or removed when `choice` is nil.
    public func choosing(_ choice: DisplayChoice?, forDisplay display: String) -> KinoraSelection {
        var displays = self.displays ?? [:]
        displays[display] = choice
        return KinoraSelection(rules: rules, displays: displays)
    }

    /// The selection without `id`. A display whose wallpaper it was goes back to the main rules;
    /// one whose Lock Screen it was goes back to the main Lock Screen. Nil when the main rules
    /// would have nothing left to show, as for `WallpaperRules.removing`.
    public func removing(_ id: UUID, replacement: UUID? = nil, at date: Date = Date()) -> KinoraSelection? {
        guard let main = rules.uses(of: id).isEmpty ? rules : rules.removing(id, replacement: replacement, at: date) else { return nil }
        var kept: [String: DisplayChoice] = [:]
        for (display, choice) in displays ?? [:] where choice.wallpaper != id {
            var choice = choice
            if choice.lockScreen == id { choice.lockScreen = nil }
            kept[display] = choice
        }
        return KinoraSelection(rules: main, displays: kept)
    }
}
