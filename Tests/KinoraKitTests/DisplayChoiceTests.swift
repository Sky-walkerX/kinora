// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

@Suite struct DisplayChoiceTests {
    let a = UUID(), b = UUID(), c = UUID(), lock = UUID(), night = UUID()
    let builtIn = "37D8832A-2D66-02CA-B9F7-8F30A301B230", external = "9B1C9E6A-0000-4000-8000-0000000000AA"
    let noon = Date(timeIntervalSince1970: 1_800_000_000)

    func resolve(_ selection: KinoraSelection, _ mode: PresentationMode = .default, display: String?,
                 library: [UUID]? = nil, appearance: SystemAppearance = .light) -> SurfaceResolution {
        SurfaceResolution.resolve(configuration: ChoiceConfiguration(wallpaper: a, followsKinora: true), selection: selection,
                                  mode: mode, appearance: appearance, at: noon, unlockCount: 0,
                                  library: library ?? [a, b, c, lock, night], originalsAvailable: false, display: display)
    }

    @Test func aDisplayWithItsOwnChoiceShowsItAndTheOthersFollowTheMainRules() {
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: a), displays: [external: DisplayChoice(wallpaper: b)])
        #expect(resolve(selection, display: external).shown == b)
        #expect(resolve(selection, display: builtIn).shown == a)
        // A surface whose display macOS didn't name follows the main rules.
        #expect(resolve(selection, display: nil).shown == a)
    }

    @Test func theLockScreenFollowsTheMainLockScreenUnlessTheDisplayHasItsOwn() {
        let main = WallpaperRules(wallpaper: a, lockScreen: lock)
        let inherits = KinoraSelection(rules: main, displays: [external: DisplayChoice(wallpaper: b)])
        #expect(resolve(inherits, .locked, display: external).shown == lock)
        let own = KinoraSelection(rules: main, displays: [external: DisplayChoice(wallpaper: b, lockScreen: c)])
        #expect(resolve(own, .locked, display: external).shown == c)
        #expect(resolve(own, .locked, display: builtIn).shown == lock)
        // Without a Lock Screen anywhere, the display's Lock Screen shows its own wallpaper.
        let plain = KinoraSelection(rules: WallpaperRules(wallpaper: a), displays: [external: DisplayChoice(wallpaper: b)])
        #expect(resolve(plain, .locked, display: external).shown == b)
    }

    @Test func aDisplaysChoiceIsFixedWhileTheMainRulesRotateAndChangeWithDarkMode() {
        let rotation = WallpaperRules.Rotation(items: [a, c], interval: 60, since: noon.addingTimeInterval(-90))
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: a, dark: night, rotation: rotation),
                                        displays: [external: DisplayChoice(wallpaper: b)])
        #expect(resolve(selection, display: builtIn).shown == c)
        #expect(resolve(selection, display: external).shown == b)
        #expect(resolve(selection, display: external, appearance: .dark).shown == b)
        #expect(selection.rules(forDisplay: external).nextChange(after: noon) == nil)
    }

    @Test func aRemovedDisplayItemFallsBackToTheMainWallpaper() {
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: a), displays: [external: DisplayChoice(wallpaper: b)])
        let resolution = resolve(selection, display: external, library: [a, c])
        #expect(resolution.wanted == b)
        #expect(resolution.shown == a)
    }

    @Test func choicesThatDoNotFollowKinoraIgnoreDisplays() {
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: a), displays: [external: DisplayChoice(wallpaper: b)])
        #expect(ChoiceConfiguration(wallpaper: c).rules(selection: selection, display: external).wallpaper == c)
        #expect(ChoiceConfiguration(wallpaper: c, followsKinora: true).rules(selection: selection, display: external).wallpaper == b)
    }

    @Test func choosingSetsAndClearsOneDisplay() {
        let start = KinoraSelection(rules: WallpaperRules(wallpaper: a))
        let set = start.choosing(DisplayChoice(wallpaper: b, name: "Studio Display"), forDisplay: external)
        #expect(set.displays?[external]?.wallpaper == b)
        #expect(set.rules == start.rules)
        let cleared = set.choosing(nil, forDisplay: external)
        // No empty dictionary is left behind, so the file reads as before.
        #expect(cleared.displays == nil)
        #expect(cleared == start)
    }

    @Test func listsAndFindsItemsOnEveryDisplay() {
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: a, lockScreen: lock),
                                        displays: [external: DisplayChoice(wallpaper: b, lockScreen: c)])
        #expect(selection.allItems == [a, lock, b, c])
        #expect(selection.uses(of: b) == [.display])
        #expect(selection.uses(of: c) == [.display])
        #expect(selection.uses(of: lock) == [.lockScreen])
        #expect(selection.uses(of: night).isEmpty)
        #expect(RuleUse.display.description == "a display's own wallpaper")
    }

    @Test func removingAnItemTakesItOffEveryDisplay() throws {
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: a),
                                        displays: [external: DisplayChoice(wallpaper: b, lockScreen: c), builtIn: DisplayChoice(wallpaper: c)])
        let withoutB = try #require(selection.removing(b, at: noon))
        // The display whose wallpaper it was goes back to the main rules.
        #expect(withoutB.displays?[external] == nil)
        #expect(withoutB.displays?[builtIn]?.wallpaper == c)
        let withoutC = try #require(selection.removing(c, at: noon))
        #expect(withoutC.displays?[external] == DisplayChoice(wallpaper: b))
        #expect(withoutC.displays?[builtIn] == nil)
        #expect(withoutC.rules == selection.rules)
    }

    @Test func removingTheMainWallpaperStillNeedsSomethingElseToShow() throws {
        let only = KinoraSelection(rules: WallpaperRules(wallpaper: a), displays: [external: DisplayChoice(wallpaper: b)])
        #expect(only.removing(a, at: noon) == nil)
        let replaced = try #require(only.removing(a, replacement: c, at: noon))
        #expect(replaced.rules.wallpaper == c)
        #expect(replaced.displays?[external]?.wallpaper == b)
    }

    @Test func roundTripsAndReadsSelectionsWrittenBeforeDisplays() throws {
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: a), displays: [external: DisplayChoice(wallpaper: b, name: "Studio Display")])
        #expect(KinoraSelection.decode(try selection.encoded()) == selection)
        let old = #"{"rules":{"wallpaper":"\#(a.uuidString)"},"version":1}"#
        let decoded = try #require(KinoraSelection.decode(Data(old.utf8)))
        #expect(decoded.displays == nil)
        #expect(decoded.rules(forDisplay: external).wallpaper == a)
        // Without displays the file has no displays key, so it is byte for byte what older versions wrote.
        let plain = String(decoding: try KinoraSelection(rules: WallpaperRules(wallpaper: a)).encoded(), as: UTF8.self)
        #expect(!plain.contains("displays"))
    }

    @Test func aDamagedDisplayNameIsCut() {
        let choice = DisplayChoice(wallpaper: a, name: String(repeating: "x", count: 500))
        #expect(choice.name?.count == DisplayChoice.maxNameLength)
    }
}
