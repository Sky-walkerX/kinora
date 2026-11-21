// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// Which library item to show, and when. A rules value lives either inside a choice in macOS's
/// wallpaper store (a tile picked in System Settings) or in Kinora's `selection.json`, which the
/// plug-in follows live so changes need no WallpaperAgent restart.
public struct WallpaperRules: Codable, Equatable, Sendable {
    /// The desktop's item when nothing more specific applies.
    public var wallpaper: UUID
    /// The Lock Screen's item; the desktop's when nil.
    public var lockScreen: UUID?
    /// The desktop's item while the Mac uses the dark appearance.
    public var dark: UUID?
    /// The desktop cycles through these items.
    public var rotation: Rotation?
    /// The desktop changes at these times of day. Takes precedence over rotation and dark.
    public var schedule: [ScheduleEntry]?

    public struct Rotation: Codable, Equatable, Sendable {
        public var items: [UUID]
        /// Seconds between changes. Zero changes on every unlock instead.
        public var interval: TimeInterval
        /// When the rotation started, so every surface and every restart agrees on the item.
        public var since: Date
        /// The playlist the items came from, so the app can name it and keep it in step.
        public var playlist: UUID?
        /// Plays the items in a shuffled order, a new one on every pass.
        public var shuffle: Bool?
        /// Steps skipped with "Next".
        public var offset: Int?

        public init(items: [UUID], interval: TimeInterval, since: Date, playlist: UUID? = nil, shuffle: Bool = false, offset: Int = 0) {
            self.items = items
            self.interval = interval
            self.since = since
            self.playlist = playlist
            self.shuffle = shuffle ? true : nil
            self.offset = offset == 0 ? nil : offset
        }

        /// How many changes have happened by `date`, counting skips.
        public func step(at date: Date, unlockCount: Int) -> Int {
            let elapsed = interval > 0 ? Int(min(Double(Int.max / 2), max(0, date.timeIntervalSince(since)) / interval)) : max(0, unlockCount)
            return max(0, elapsed + (offset ?? 0))
        }

        /// The item shown at a step.
        public func item(atStep step: Int) -> UUID? {
            guard !items.isEmpty else { return nil }
            let count = items.count
            guard shuffle == true, count > 1 else { return items[step % count] }
            // Two items can only alternate without repeating; shuffling just picks which goes first.
            if count == 2 { return Self.shuffled(items, pass: 0, seed: since)[step % 2] }
            let pass = step / count
            var order = Self.shuffled(items, pass: pass, seed: since)
            // A new pass never starts with the item the previous pass ended on. The swap touches
            // only the first two places, so with three or more items the previous pass's last
            // item is the same before and after its own swap.
            if pass > 0, order.first == Self.shuffled(items, pass: pass - 1, seed: since).last { order.swapAt(0, 1) }
            return order[step % count]
        }

        /// The rotation with new items, keeping the wallpaper on screen when it is still in the
        /// list, else moving to the one that would have come next. A timed rotation is started
        /// again from `date` for that; one that steps on each unlock keeps its place, as only the
        /// plug-in counts unlocks.
        public func replacingItems(_ newItems: [UUID], at date: Date) -> Rotation {
            changing(items: newItems, at: date)
        }

        /// The rotation with new items, order or pace, keeping the wallpaper on screen as
        /// `replacingItems` does. A rotation that steps on unlock keeps its place when only its
        /// items change, and otherwise starts again from its first item.
        public func changing(items newItems: [UUID]? = nil, shuffle newShuffle: Bool? = nil, interval newInterval: TimeInterval? = nil,
                             at date: Date) -> Rotation {
            var rotation = self
            if let newItems { rotation.items = newItems }
            if let newShuffle { rotation.shuffle = newShuffle ? true : nil }
            if let newInterval { rotation.interval = newInterval }
            guard rotation != self, !rotation.items.isEmpty, !items.isEmpty else { return rotation }
            let onlyItems = rotation.shuffle == shuffle && rotation.interval == interval
            if interval <= 0, onlyItems { return rotation }
            // Selections store whole seconds, so the anchor must be one for every process to agree.
            rotation.since = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
            rotation.offset = nil
            guard interval > 0 else { return rotation }
            let current = step(at: date, unlockCount: 0)
            let kept = Set(rotation.items)
            // The item on screen, else the first of the items after it that survives.
            let target = (0..<items.count).lazy.compactMap { item(atStep: current + $0) }.first(where: kept.contains) ?? rotation.items[0]
            if let index = (0..<rotation.items.count).first(where: { rotation.item(atStep: $0) == target }), index > 0 {
                rotation.offset = index
            }
            return rotation
        }

        /// A permutation every process computes the same way. Swift's own hashing is seeded per
        /// process, so this uses FNV-1a over the identifier, the start time and the pass.
        static func shuffled(_ items: [UUID], pass: Int, seed: Date) -> [UUID] {
            let seedBits = UInt64(bitPattern: Int64((seed.timeIntervalSince1970 * 1000).rounded()))
            func key(_ id: UUID) -> UInt64 {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                func mix(_ byte: UInt8) { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
                withUnsafeBytes(of: id.uuid) { $0.forEach(mix) }
                withUnsafeBytes(of: seedBits.littleEndian) { $0.forEach(mix) }
                withUnsafeBytes(of: UInt64(truncatingIfNeeded: pass).littleEndian) { $0.forEach(mix) }
                return hash
            }
            return items.map { ($0, key($0)) }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.uuidString < $1.0.uuidString }.map(\.0)
        }
    }

    public struct ScheduleEntry: Codable, Equatable, Sendable {
        /// Minutes after midnight, 0..<1440.
        public var startMinute: Int
        public var item: UUID

        public init(startMinute: Int, item: UUID) {
            self.startMinute = startMinute
            self.item = item
        }
    }

    public init(wallpaper: UUID, lockScreen: UUID? = nil, dark: UUID? = nil, rotation: Rotation? = nil, schedule: [ScheduleEntry]? = nil) {
        self.wallpaper = wallpaper
        self.lockScreen = lockScreen
        self.dark = dark
        self.rotation = rotation
        self.schedule = schedule
    }

    /// Every item the rules can show, for checking they all still exist.
    public var allItems: Set<UUID> {
        var items: Set<UUID> = [wallpaper]
        if let lockScreen { items.insert(lockScreen) }
        if let dark { items.insert(dark) }
        items.formUnion(rotation?.items ?? [])
        items.formUnion(schedule?.map(\.item) ?? [])
        return items
    }

    /// The item to draw now.
    public func item(for mode: PresentationMode, appearance: SystemAppearance, at date: Date,
                     calendar: Calendar = .current, unlockCount: Int = 0) -> UUID {
        if mode == .locked, let lockScreen { return lockScreen }
        if let entry = currentScheduleEntry(at: date, calendar: calendar) { return entry.item }
        if let rotation, let item = rotation.item(atStep: rotation.step(at: date, unlockCount: unlockCount)) {
            return item
        }
        if appearance == .dark, let dark { return dark }
        return wallpaper
    }

    /// When the item may next change by itself (a schedule boundary or rotation step), so the
    /// plug-in can set one timer instead of polling. Nil when nothing changes over time.
    public func nextChange(after date: Date, calendar: Calendar = .current) -> Date? {
        var candidates: [Date] = []
        if let schedule, !schedule.isEmpty {
            let starts = Set(schedule.map { min(1439, max(0, $0.startMinute)) })
            for minute in starts {
                let components = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
                if let next = calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime) { candidates.append(next) }
            }
        } else if let rotation, rotation.items.count > 1, rotation.interval > 0 {
            let elapsed = max(0, date.timeIntervalSince(rotation.since))
            candidates.append(rotation.since.addingTimeInterval((floor(elapsed / rotation.interval) + 1) * rotation.interval))
        }
        return candidates.min()
    }

    /// The schedule entry in force: the latest start at or before now, wrapping past midnight.
    func currentScheduleEntry(at date: Date, calendar: Calendar) -> ScheduleEntry? {
        guard let schedule, !schedule.isEmpty else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let sorted = schedule.sorted { $0.startMinute < $1.startMinute }
        return sorted.last { $0.startMinute <= now } ?? sorted.last
    }
}

/// Kinora's live selection, followed by every surface whose choice says `followsKinora`.
public struct KinoraSelection: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var rules: WallpaperRules

    public init(rules: WallpaperRules) {
        self.version = Self.currentVersion
        self.rules = rules
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> KinoraSelection? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KinoraSelection.self, from: data)
    }
}
