// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

/// Fixes from the 2026-11-21 audit of the library rules.
@Suite struct RulesAuditTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func twoItemShufflesAlternateWithoutRepeating() {
        for seed in 0..<50 {
            let rotation = WallpaperRules.Rotation(items: [a, b], interval: 60, since: at(Double(seed) * 7.3), shuffle: true)
            let shown = (0..<40).compactMap { rotation.item(atStep: $0) }
            #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 != $1 }, "seed \(seed)")
            #expect(Set(shown) == [a, b])
        }
    }

    @Test func longerShufflesNeverRepeatAcrossPasses() {
        for count in 3...6 {
            let items = (0..<count).map { _ in UUID() }
            let rotation = WallpaperRules.Rotation(items: items, interval: 60, since: start, shuffle: true)
            let shown = (0..<(count * 30)).compactMap { rotation.item(atStep: $0) }
            #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 != $1 })
        }
    }

    @Test func removingAnotherItemKeepsTheWallpaperOnScreen() throws {
        // Step 5 of [a, b, c, d] shows b; removing d used to jump to c (5 % 3).
        let rotation = WallpaperRules.Rotation(items: [a, b, c, d], interval: 60, since: start)
        let now = at(5 * 60 + 10)
        #expect(rotation.item(atStep: rotation.step(at: now, unlockCount: 0)) == b)
        let rules = try #require(WallpaperRules(wallpaper: a, rotation: rotation).removing(d, at: now))
        let edited = try #require(rules.rotation)
        #expect(edited.items == [a, b, c])
        #expect(rules.item(for: .default, appearance: .light, at: now) == b)
        // It then carries on in order, one interval later.
        #expect(rules.item(for: .default, appearance: .light, at: now.addingTimeInterval(61)) == c)
        // Selections store whole seconds, so the new start must be one.
        #expect(edited.since.timeIntervalSince1970 == edited.since.timeIntervalSince1970.rounded(.down))
    }

    @Test func removingTheWallpaperOnScreenMovesToTheNextOne() throws {
        let rotation = WallpaperRules.Rotation(items: [a, b, c, d], interval: 60, since: start)
        let now = at(5 * 60 + 10) // b
        let rules = try #require(WallpaperRules(wallpaper: a, rotation: rotation).removing(b, at: now))
        #expect(rules.item(for: .default, appearance: .light, at: now) == c)
    }

    @Test func addingItemsKeepsTheWallpaperOnScreenInShuffles() {
        let rotation = WallpaperRules.Rotation(items: [a, b, c], interval: 3600, since: start, shuffle: true)
        let now = at(7 * 3600 + 5)
        let before = rotation.item(atStep: rotation.step(at: now, unlockCount: 0))
        let grown = rotation.replacingItems([a, b, c, d], at: now)
        #expect(grown.item(atStep: grown.step(at: now, unlockCount: 0)) == before)
        #expect(grown.shuffle == true && grown.items.count == 4)
    }

    @Test func unlockRotationsKeepTheirPlace() {
        // Only the plug-in counts unlocks, so the app can't tell what is on screen: keep the count.
        let rotation = WallpaperRules.Rotation(items: [a, b, c], interval: 0, since: start, offset: 2)
        let edited = rotation.replacingItems([a, c], at: at(999))
        #expect(edited.since == start && edited.offset == 2 && edited.items == [a, c])
    }

    @Test func unchangedItemsChangeNothing() {
        let rotation = WallpaperRules.Rotation(items: [a, b], interval: 60, since: start, offset: 3)
        #expect(rotation.replacingItems([a, b], at: at(500)) == rotation)
    }

    @Test func reshufflingOrRepacingKeepsTheWallpaperOnScreen() {
        let rotation = WallpaperRules.Rotation(items: [a, b, c, d], interval: 600, since: start)
        let now = at(6 * 600 + 42) // step 6: c
        #expect(rotation.item(atStep: rotation.step(at: now, unlockCount: 0)) == c)
        let shuffled = rotation.changing(shuffle: true, at: now)
        #expect(shuffled.shuffle == true)
        #expect(shuffled.item(atStep: shuffled.step(at: now, unlockCount: 0)) == c)
        let hourly = shuffled.changing(interval: 3600, at: now)
        #expect(hourly.interval == 3600 && hourly.item(atStep: hourly.step(at: now, unlockCount: 0)) == c)
        // Switching to "each unlock" starts the plug-in's count again from this item.
        let onUnlock = rotation.changing(interval: 0, at: now)
        #expect(onUnlock.item(atStep: onUnlock.step(at: now, unlockCount: 0)) == c)
        // From "each unlock", which only the plug-in can place, a new pace starts at the beginning.
        let fromUnlock = WallpaperRules.Rotation(items: [a, b, c], interval: 0, since: start, offset: 1).changing(interval: 60, at: now)
        #expect(fromUnlock.offset == nil && fromUnlock.item(atStep: fromUnlock.step(at: now, unlockCount: 0)) == a)
    }

    @Test func findsScheduleTimesUsedTwice() {
        let entries: [WallpaperRules.ScheduleEntry] = [.init(startMinute: 420, item: a), .init(startMinute: 1140, item: b),
                                                       .init(startMinute: 420, item: c), .init(startMinute: 2000, item: d),
                                                       .init(startMinute: 1439, item: a)]
        #expect(ScheduleEditing.duplicateStarts(entries) == [420, 1439])
        #expect(ScheduleEditing.duplicateStarts(ScheduleEditing.dayAndNight(day: a, night: b)).isEmpty)
    }

    @Test func spotsIndexesThatWouldLoseData() throws {
        let item = LibraryItem(name: "a", kind: .video, media: "a.mov", thumbnail: "a.png", addedAt: start)
        let good = try LibraryIndex(items: [item], playlists: [Playlist(name: "P", items: [item.id])]).encoded()
        #expect(!LibraryIndex.decodingLosesData(good))
        #expect(LibraryIndex.decodingLosesData(Data("not json".utf8)))
        #expect(LibraryIndex.decodingLosesData(Data(#"{"items": []}"#.utf8)))
        let newer = #"{"version": 99, "items": []}"#
        #expect(LibraryIndex.decodingLosesData(Data(newer.utf8)))
        let broken = #"{"version": 1, "items": [{"id": "x"}]}"#
        #expect(LibraryIndex.decodingLosesData(Data(broken.utf8)))
        let path = #"{"version": 1, "items": [{"id":"\#(UUID().uuidString)","name":"p","kind":"video","media":"../p.mov","thumbnail":"p.png","addedAt":"2026-11-12T00:00:00Z"}]}"#
        #expect(LibraryIndex.decodingLosesData(Data(path.utf8)))
        let badPlaylist = #"{"version": 1, "items": [], "playlists": [{"name": 3}]}"#
        #expect(LibraryIndex.decodingLosesData(Data(badPlaylist.utf8)))
    }
}
