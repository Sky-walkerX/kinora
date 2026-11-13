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
            let pass = step / count
            var order = Self.shuffled(items, pass: pass, seed: since)
            // A new pass never starts with the item the previous pass ended on.
            if pass > 0, order.first == Self.shuffled(items, pass: pass - 1, seed: since).last { order.swapAt(0, 1) }
            return order[step % count]
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
