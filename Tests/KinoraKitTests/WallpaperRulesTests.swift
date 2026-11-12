// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

@Suite struct WallpaperRulesTests {
    let a = UUID(), b = UUID(), c = UUID(), lock = UUID(), night = UUID()
    var calendar: Calendar { var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!; return cal }
    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: hour, minute: minute))!
    }

    @Test func plainRulesShowTheWallpaperEverywhereExceptAChosenLockScreen() {
        let rules = WallpaperRules(wallpaper: a, lockScreen: lock)
        #expect(rules.item(for: .default, appearance: .light, at: at(9), calendar: calendar) == a)
        #expect(rules.item(for: .idle, appearance: .light, at: at(9), calendar: calendar) == a)
        #expect(rules.item(for: .locked, appearance: .light, at: at(9), calendar: calendar) == lock)
        #expect(WallpaperRules(wallpaper: a).item(for: .locked, appearance: .light, at: at(9), calendar: calendar) == a)
    }

    @Test func darkAppearanceUsesTheDarkItem() {
        let rules = WallpaperRules(wallpaper: a, dark: night)
        #expect(rules.item(for: .default, appearance: .dark, at: at(9), calendar: calendar) == night)
        #expect(rules.item(for: .default, appearance: .light, at: at(9), calendar: calendar) == a)
    }

    @Test func timedRotationStepsOnTheIntervalForEveryone() {
        let rotation = WallpaperRules.Rotation(items: [a, b, c], interval: 3600, since: at(8))
        let rules = WallpaperRules(wallpaper: a, rotation: rotation)
        #expect(rules.item(for: .default, appearance: .light, at: at(8, 30), calendar: calendar) == a)
        #expect(rules.item(for: .default, appearance: .light, at: at(9, 1), calendar: calendar) == b)
        #expect(rules.item(for: .default, appearance: .light, at: at(11, 0), calendar: calendar) == a)
        #expect(rules.nextChange(after: at(8, 30), calendar: calendar) == at(9))
    }

    @Test func unlockRotationStepsOnEachUnlock() {
        let rules = WallpaperRules(wallpaper: a, rotation: .init(items: [a, b], interval: 0, since: at(8)))
        #expect(rules.item(for: .default, appearance: .light, at: at(9), calendar: calendar, unlockCount: 0) == a)
        #expect(rules.item(for: .default, appearance: .light, at: at(9), calendar: calendar, unlockCount: 1) == b)
        #expect(rules.nextChange(after: at(9), calendar: calendar) == nil)
    }

    @Test func scheduleWinsAndWrapsPastMidnight() {
        let rules = WallpaperRules(wallpaper: a, dark: night, rotation: .init(items: [b, c], interval: 60, since: at(0)),
                                   schedule: [.init(startMinute: 7 * 60, item: a), .init(startMinute: 19 * 60, item: night)])
        #expect(rules.item(for: .default, appearance: .light, at: at(12), calendar: calendar) == a)
        #expect(rules.item(for: .default, appearance: .light, at: at(20), calendar: calendar) == night)
        #expect(rules.item(for: .default, appearance: .light, at: at(3), calendar: calendar) == night)
        #expect(rules.nextChange(after: at(12), calendar: calendar) == at(19))
    }

    @Test func listsEveryItemItCanShow() {
        let rules = WallpaperRules(wallpaper: a, lockScreen: lock, dark: night, rotation: .init(items: [b], interval: 0, since: at(0)),
                                   schedule: [.init(startMinute: 0, item: c)])
        #expect(rules.allItems == [a, lock, night, b, c])
    }

    @Test func selectionRoundTrips() throws {
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: a, rotation: .init(items: [a, b], interval: 600, since: at(8))))
        #expect(KinoraSelection.decode(try selection.encoded()) == selection)
    }

    @Test func choicesFollowKinoraOnlyWhenTheySaySo() {
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: b))
        #expect(ChoiceConfiguration(wallpaper: a, followsKinora: true).rules(selection: selection).wallpaper == b)
        #expect(ChoiceConfiguration(wallpaper: a, followsKinora: true).rules(selection: nil).wallpaper == a)
        #expect(ChoiceConfiguration(wallpaper: a).rules(selection: selection).wallpaper == a)
    }

    @Test func versionOneChoicesStillDecode() throws {
        let v1 = #"{"lockScreen":"\#(lock.uuidString)","version":1,"wallpaper":"\#(a.uuidString)"}"#
        let decoded = try #require(ChoiceConfiguration.decode(Data(v1.utf8)))
        #expect(!decoded.follows)
        #expect(decoded.rules(selection: nil) == WallpaperRules(wallpaper: a, lockScreen: lock))
    }
}
