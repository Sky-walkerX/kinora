// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

@Suite struct UnlockCounterTests {
    let since = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countsOneUnlockHoweverManySurfacesReportIt() {
        var counter = UnlockCounter()
        // Two displays lock, then both unlock a few milliseconds apart.
        counter.surface(from: .default, to: .locked)
        counter.surface(from: .default, to: .locked)
        #expect(counter.surface(from: .locked, to: .default))
        #expect(!counter.surface(from: .locked, to: .default))
        #expect(counter.count == 1)
        // The next lock counts again.
        counter.surface(from: .default, to: .locked)
        counter.surface(from: .locked, to: .default)
        #expect(counter.count == 2)
    }

    @Test func ignoresChangesThatAreNotAnUnlock() {
        var counter = UnlockCounter()
        #expect(!counter.surface(from: .default, to: .idle))
        #expect(!counter.surface(from: .idle, to: .default))
        #expect(!counter.surface(from: .locked, to: .default))
        #expect(!counter.surface(from: nil, to: .default))
        #expect(counter.count == 0)
    }

    @Test func aSurfaceAcquiredWhileLockedCountsTheNextUnlock() {
        var counter = UnlockCounter()
        counter.surface(from: nil, to: .locked)
        #expect(counter.surface(from: .locked, to: .default))
    }

    @Test func belongsToOneRotation() {
        var counter = UnlockCounter()
        let rotation = WallpaperRules.Rotation(items: [UUID(), UUID()], interval: 0, since: since)
        counter.follow(rotation)
        counter.surface(from: .default, to: .locked)
        counter.surface(from: .locked, to: .default)
        // The same rotation, skipped ahead with Next, keeps its count.
        var skipped = rotation
        skipped.offset = 1
        #expect(!counter.follow(skipped))
        #expect(counter.count == 1)
        // A new rotation starts from its first item.
        #expect(counter.follow(.init(items: rotation.items, interval: 0, since: since.addingTimeInterval(60))))
        #expect(counter.count == 0)
        // Timed rotations and no rotation don't count unlocks.
        counter.surface(from: .default, to: .locked)
        counter.surface(from: .locked, to: .default)
        counter.follow(.init(items: rotation.items, interval: 600, since: since))
        #expect(counter.count == 0)
        #expect(counter.rotationSince == nil)
    }

    @Test func survivesARestart() throws {
        var counter = UnlockCounter()
        counter.follow(.init(items: [UUID(), UUID()], interval: 0, since: since))
        counter.surface(from: .default, to: .locked)
        counter.surface(from: .locked, to: .default)
        let restored = try #require(UnlockCounter.decode(counter.encoded()))
        #expect(restored.count == 1)
        #expect(restored.rotationSince == since)
        #expect(UnlockCounter.decode(Data("junk".utf8)) == nil)
        #expect(UnlockCounter.decode(Data(#"{"count": -4}"#.utf8))?.count == 0)
    }
}

@Suite struct SurfaceResolutionTests {
    let a = UUID(), b = UUID(), c = UUID(), lock = UUID()
    let noon = Date(timeIntervalSince1970: 1_800_000_000)

    func resolve(_ configuration: ChoiceConfiguration?, _ selection: KinoraSelection?, mode: PresentationMode = .default,
                 library: [UUID], originals: Bool = false, unlocks: Int = 0) -> SurfaceResolution {
        SurfaceResolution.resolve(configuration: configuration, selection: selection, mode: mode, appearance: .light,
                                  at: noon, unlockCount: unlocks, library: library, originalsAvailable: originals)
    }

    @Test func followsTheSelectionWhenTheChoiceSaysSo() {
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: b, lockScreen: lock))
        let following = ChoiceConfiguration(wallpaper: a, followsKinora: true)
        #expect(resolve(following, selection, library: [a, b, lock]).shown == b)
        #expect(resolve(following, selection, mode: .locked, library: [a, b, lock]).shown == lock)
        // A tile picked in System Settings shows its own item.
        #expect(resolve(ChoiceConfiguration(wallpaper: a), selection, library: [a, b, lock]).shown == a)
        // A preview carries no configuration and shows the selection.
        #expect(resolve(nil, selection, library: [a, b, lock]).shown == b)
    }

    @Test func aRemovedItemFallsBackTheWayThePlugInDoes() {
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: b))
        // A System Settings tile naming an item that was removed shows Kinora's main wallpaper.
        let tile = ChoiceConfiguration(wallpaper: a)
        let resolution = resolve(tile, selection, library: [b, c])
        #expect(resolution.wanted == a)
        #expect(resolution.shown == b)
        // With the selection's wallpaper gone too, the first library item.
        #expect(resolve(tile, KinoraSelection(rules: WallpaperRules(wallpaper: a)), library: [c]).shown == c)
        // With an empty library, an original when Metal works, else nothing.
        let original = KinoraOriginals.all[0].id
        #expect(resolve(tile, nil, library: [], originals: true).shown == original)
        #expect(resolve(tile, nil, library: [], originals: false).shown == nil)
    }

    @Test func originalsNeedMetal() {
        let original = KinoraOriginals.all[0].id
        let tile = ChoiceConfiguration(wallpaper: original)
        #expect(resolve(tile, nil, library: [a], originals: true).shown == original)
        #expect(resolve(tile, nil, library: [a], originals: false).shown == a)
    }

    @Test func saysWhenOnlyThePlugInKnowsTheItem() {
        let rotation = WallpaperRules.Rotation(items: [a, b], interval: 0, since: noon)
        let selection = KinoraSelection(rules: WallpaperRules(wallpaper: a, lockScreen: lock, rotation: rotation))
        let following = ChoiceConfiguration(wallpaper: a, followsKinora: true)
        #expect(resolve(following, selection, library: [a, b, lock]).dependsOnUnlocks)
        #expect(resolve(following, selection, library: [a, b, lock], unlocks: 1).shown == b)
        // The Lock Screen has its own wallpaper, which doesn't rotate.
        #expect(!resolve(following, selection, mode: .locked, library: [a, b, lock]).dependsOnUnlocks)
        // A timed rotation is known to everyone.
        let timed = KinoraSelection(rules: WallpaperRules(wallpaper: a, rotation: .init(items: [a, b], interval: 60, since: noon)))
        #expect(!resolve(following, timed, library: [a, b]).dependsOnUnlocks)
    }

    @Test func aScheduleOrRotationOverridesTheDarkVariant() {
        #expect(!WallpaperRules(wallpaper: a, dark: b).darkVariantIsOverridden)
        #expect(WallpaperRules(wallpaper: a, dark: b, rotation: .init(items: [a, c], interval: 60, since: noon)).darkVariantIsOverridden)
        #expect(WallpaperRules(wallpaper: a, dark: b, schedule: [.init(startMinute: 0, item: c)]).darkVariantIsOverridden)
        #expect(!WallpaperRules(wallpaper: a, rotation: .init(items: [a, c], interval: 60, since: noon)).darkVariantIsOverridden)
    }
}
