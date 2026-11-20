// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// Counts unlocks for rotations that change "each time you unlock".
///
/// WallpaperAgent sends every surface its own update: one per display, and the screen saver's
/// too. A single unlock therefore arrives several times, a few milliseconds apart. Counting each
/// one would skip items on a Mac with two displays, and a two-item rotation would never change.
/// The counter counts once per lock, however many surfaces report it.
///
/// The count belongs to one rotation, identified by its start time, so a new rotation starts
/// from its first item. The plug-in keeps the counter in its own preferences so a restart of
/// WallpaperAgent or the plug-in does not send the rotation back to the start.
public struct UnlockCounter: Codable, Equatable, Sendable {
    /// Unlocks counted for `rotationSince`.
    public private(set) var count: Int
    /// The start time of the rotation the count belongs to.
    public private(set) var rotationSince: Date?
    /// True between a surface locking and the first surface unlocking. Not saved: a plug-in that
    /// starts while the Mac is locked is told so by the surfaces it acquires.
    private var locked = false

    public init(count: Int = 0, rotationSince: Date? = nil) {
        self.count = max(0, count)
        self.rotationSince = rotationSince
    }

    private enum CodingKeys: String, CodingKey { case count, rotationSince }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = max(0, try c.decodeIfPresent(Int.self, forKey: .count) ?? 0)
        rotationSince = try c.decodeIfPresent(Date.self, forKey: .rotationSince)
    }

    /// A surface moved between presentations. Returns true when this counted an unlock.
    @discardableResult
    public mutating func surface(from old: PresentationMode?, to new: PresentationMode) -> Bool {
        if new == .locked {
            locked = true
            return false
        }
        guard old == .locked, new == .default, locked else { return false }
        locked = false
        count += 1
        return true
    }

    /// Keeps the count with the rotation in force. A different rotation, or none, starts again at zero.
    /// Returns true when the count was reset.
    @discardableResult
    public mutating func follow(_ rotation: WallpaperRules.Rotation?) -> Bool {
        let since = rotation.flatMap { $0.interval > 0 ? nil : $0.since }
        guard since != rotationSince else { return false }
        rotationSince = since
        let wasCounting = count != 0
        count = 0
        return wasCounting
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func decode(_ data: Data?) -> UnlockCounter? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(UnlockCounter.self, from: data)
    }
}

/// What a surface shows. The plug-in uses it to draw and the app uses it to say what is on
/// screen, so the two can never disagree: the item the rules want, or, when that item has been
/// removed, the same fallbacks the plug-in falls back to.
public struct SurfaceResolution: Equatable, Sendable {
    /// The item the rules name for this moment, whether or not it still exists.
    public var wanted: UUID?
    /// The item the surface draws. Nil only when nothing at all is left to show.
    public var shown: UUID?
    /// True when the item changes on each unlock, which only the plug-in can count.
    public var dependsOnUnlocks: Bool

    public init(wanted: UUID?, shown: UUID?, dependsOnUnlocks: Bool) {
        self.wanted = wanted
        self.shown = shown
        self.dependsOnUnlocks = dependsOnUnlocks
    }

    /// - Parameters:
    ///   - configuration: the choice macOS hands the plug-in, or nil for a preview.
    ///   - selection: Kinora's live selection.
    ///   - library: the library's items, in order.
    ///   - originalsAvailable: whether Kinora's originals can be drawn (they need Metal).
    public static func resolve(configuration: ChoiceConfiguration?, selection: KinoraSelection?,
                               mode: PresentationMode, appearance: SystemAppearance, at date: Date,
                               calendar: Calendar = .current, unlockCount: Int,
                               library: [UUID], originalsAvailable: Bool) -> SurfaceResolution {
        let rules = configuration?.rules(selection: selection) ?? selection?.rules
        let wanted = rules?.item(for: mode, appearance: appearance, at: date, calendar: calendar, unlockCount: unlockCount)
        var fallbacks: [UUID] = []
        if let main = selection?.rules.wallpaper { fallbacks.append(main) }
        fallbacks.append(contentsOf: library)
        if originalsAvailable { fallbacks.append(contentsOf: KinoraOriginals.all.map(\.id)) }
        let available = Set(library)
        let shown = ContentResolution.item(wanted: wanted, rules: rules, fallbacks: fallbacks) { id in
            available.contains(id) || (originalsAvailable && KinoraOriginals.isOriginal(id))
        }
        return SurfaceResolution(wanted: wanted, shown: shown, dependsOnUnlocks: rules?.changesOnUnlock(mode: mode, at: date, calendar: calendar) ?? false)
    }
}

extension WallpaperRules {
    /// True when, in `mode` at `date`, the item comes from a rotation that steps on each unlock.
    public func changesOnUnlock(mode: PresentationMode, at date: Date, calendar: Calendar = .current) -> Bool {
        if mode == .locked, lockScreen != nil { return false }
        if currentScheduleEntry(at: date, calendar: calendar) != nil { return false }
        guard let rotation, rotation.items.count > 1 else { return false }
        return rotation.interval <= 0
    }

    /// True when a dark variant is set but a rotation or schedule decides the desktop instead.
    public var darkVariantIsOverridden: Bool {
        dark != nil && ((schedule?.isEmpty == false) || (rotation?.items.isEmpty == false))
    }
}
