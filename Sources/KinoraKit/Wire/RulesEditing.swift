// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// A place in the rules where a library item is used, for telling the user what removing it changes.
public enum RuleUse: String, CaseIterable, Sendable {
    case desktop, lockScreen, dark, rotation, schedule

    public var description: String {
        switch self {
        case .desktop: "your desktop wallpaper"
        case .lockScreen: "your Lock Screen"
        case .dark: "your Dark Mode wallpaper"
        case .rotation: "the rotation"
        case .schedule: "the time-of-day schedule"
        }
    }
}

extension WallpaperRules {
    /// Where `id` appears, in a fixed order.
    public func uses(of id: UUID) -> [RuleUse] {
        var uses: [RuleUse] = []
        if wallpaper == id { uses.append(.desktop) }
        if lockScreen == id { uses.append(.lockScreen) }
        if dark == id { uses.append(.dark) }
        if rotation?.items.contains(id) == true { uses.append(.rotation) }
        if schedule?.contains(where: { $0.item == id }) == true { uses.append(.schedule) }
        return uses
    }

    /// The rules without `id`. The desktop's wallpaper becomes `replacement`, or else another
    /// item the rules already use. Nil when nothing would be left to show.
    public func removing(_ id: UUID, replacement: UUID? = nil) -> WallpaperRules? {
        var rules = self
        if rules.lockScreen == id { rules.lockScreen = nil }
        if rules.dark == id { rules.dark = nil }
        if var rotation = rules.rotation {
            rotation.items.removeAll { $0 == id }
            rules.rotation = rotation.items.isEmpty ? nil : rotation
        }
        if let schedule = rules.schedule {
            let kept = schedule.filter { $0.item != id }
            rules.schedule = kept.isEmpty ? nil : kept
        }
        if rules.wallpaper == id {
            let candidates: [UUID?] = [replacement, rules.rotation?.items.first, rules.schedule?.first?.item, rules.dark, rules.lockScreen]
            guard let next = candidates.compactMap({ $0 }).first(where: { $0 != id }) else { return nil }
            rules.wallpaper = next
        }
        return rules
    }

    /// The rules with the rotation moved on by `steps`, for "Next".
    public func advanced(by steps: Int = 1) -> WallpaperRules {
        guard var rotation, !rotation.items.isEmpty else { return self }
        rotation.offset = (rotation.offset ?? 0) + steps
        var rules = self
        rules.rotation = rotation
        return rules
    }

    /// The rules with a time-of-day schedule, tidied; an empty schedule turns it off.
    public func scheduled(_ entries: [ScheduleEntry]) -> WallpaperRules {
        var rules = self
        let tidy = ScheduleEditing.normalized(entries)
        rules.schedule = tidy.isEmpty ? nil : tidy
        return rules
    }
}

/// Helpers for editing a time-of-day schedule.
public enum ScheduleEditing {
    public static let minutesPerDay = 1440

    /// Sorted by start, minutes clamped to the day, one entry per start time (the later one in
    /// the list wins, as it is the newer edit).
    public static func normalized(_ entries: [WallpaperRules.ScheduleEntry]) -> [WallpaperRules.ScheduleEntry] {
        var byStart: [Int: WallpaperRules.ScheduleEntry] = [:]
        for entry in entries {
            let minute = min(minutesPerDay - 1, max(0, entry.startMinute))
            byStart[minute] = WallpaperRules.ScheduleEntry(startMinute: minute, item: entry.item)
        }
        return byStart.values.sorted { $0.startMinute < $1.startMinute }
    }

    /// A start time for a new entry: the middle of the longest stretch without a change,
    /// rounded to the quarter hour. 07:00 for an empty schedule, 19:00 after a single entry at 07:00.
    public static func suggestedStart(after entries: [WallpaperRules.ScheduleEntry]) -> Int {
        let starts = Array(Set(normalized(entries).map(\.startMinute))).sorted()
        guard let first = starts.first else { return 7 * 60 }
        var best = (start: first, length: 0)
        for (index, start) in starts.enumerated() {
            let next = index + 1 < starts.count ? starts[index + 1] : first + minutesPerDay
            if next - start > best.length { best = (start, next - start) }
        }
        let middle = best.start + best.length / 2
        let rounded = Int((Double(middle) / 15).rounded()) * 15
        let minute = rounded % minutesPerDay
        // Never suggest a time that is already taken.
        return starts.contains(minute) ? (minute + 15) % minutesPerDay : minute
    }

    /// A day-and-night schedule: `day` from 07:00, `night` from 19:00.
    public static func dayAndNight(day: UUID, night: UUID) -> [WallpaperRules.ScheduleEntry] {
        [.init(startMinute: 7 * 60, item: day), .init(startMinute: 19 * 60, item: night)]
    }
}

/// Picks what a surface shows when the item its rules want is gone, so a surface never goes
/// blank while anything is left to show.
public enum ContentResolution {
    /// The wanted item when it exists; else the rules' main wallpaper; else any other item the
    /// rules name; else the first of `fallbacks` that exists. Nil only when none exists.
    public static func item(wanted: UUID?, rules: WallpaperRules?, fallbacks: [UUID], exists: (UUID) -> Bool) -> UUID? {
        var candidates: [UUID] = []
        if let wanted { candidates.append(wanted) }
        if let rules {
            candidates.append(rules.wallpaper)
            candidates.append(contentsOf: rules.allItems.sorted { $0.uuidString < $1.uuidString })
        }
        candidates.append(contentsOf: fallbacks)
        return candidates.first(where: exists)
    }
}
