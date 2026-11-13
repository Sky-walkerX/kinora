// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

@Suite struct LibraryKindsAndPlaylistsTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ name: String, kind: LibraryItem.Kind = .video) -> LibraryItem {
        LibraryItem(name: name, kind: kind, media: "\(name).mov", thumbnail: "\(name).png", addedAt: date)
    }

    @Test func keepsKindsItDoesNotKnow() throws {
        let json = #"{"version":1,"items":[{"id":"\#(UUID().uuidString)","name":"Future","kind":"hologram","media":"f.mov","thumbnail":"f.png","addedAt":"2026-11-12T00:00:00Z"}]}"#
        let index = try #require(LibraryIndex.decode(Data(json.utf8)))
        #expect(index.items.count == 1)
        #expect(index.items[0].kind.rawValue == "hologram")
        let again = try #require(LibraryIndex.decode(try index.encoded()))
        #expect(again.items[0].kind == LibraryItem.Kind(rawValue: "hologram"))
    }

    @Test func librariesWithoutPlaylistsStillDecode() throws {
        let index = LibraryIndex(items: [item("a")])
        let decoded = try #require(LibraryIndex.decode(try index.encoded()))
        #expect(decoded.playlists == nil)
        #expect(decoded.items == index.items)
    }

    @Test func playlistsDropMissingAndRepeatedItems() throws {
        let a = item("a"), b = item("b")
        let ghost = UUID()
        let index = LibraryIndex(items: [a, b], playlists: [Playlist(name: "Evening", items: [b.id, ghost, a.id, b.id])])
        let decoded = try #require(LibraryIndex.decode(try index.encoded()))
        #expect(decoded.playlists?.first?.items == [b.id, a.id])
        #expect(decoded.playlists?.first?.name == "Evening")
    }

    @Test func removingAnItemTakesItOutOfPlaylists() {
        let a = item("a"), b = item("b")
        let index = LibraryIndex(items: [a, b], playlists: [Playlist(name: "Both", items: [a.id, b.id])]).removing(a.id)
        #expect(index.items == [b])
        #expect(index.playlists?.first?.items == [b.id])
    }

    @Test func applesAerialsAreNeverKinorasToDelete() {
        let location = LibraryLocation(root: URL(fileURLWithPath: "/tmp/kinora-test", isDirectory: true))
        let aerial = item("A1B2", kind: .appleAerial)
        let video = item("v")
        #expect(!aerial.ownsMedia)
        #expect(location.ownedMediaURL(for: aerial) == nil)
        #expect(location.ownedMediaURL(for: video)?.lastPathComponent == "v.mov")
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(location.mediaURL(for: aerial, home: home).path.hasPrefix("/Users/someone/Library/Application Support/com.apple.wallpaper/aerials/videos/"))
        #expect(location.mediaURL(for: video, home: home).path == "/tmp/kinora-test/Media/v.mov")
    }

    @Test func aerialsSaveNoSpace() {
        var aerial = item("x", kind: .appleAerial)
        aerial.originalBytes = 100
        aerial.storedBytes = 10
        #expect(aerial.savedBytes == 0)
    }
}

@Suite struct RulesEditingTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let since = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func listsWhereAnItemIsUsed() {
        let rules = WallpaperRules(wallpaper: a, lockScreen: b, dark: a, rotation: .init(items: [a, c], interval: 60, since: since),
                                   schedule: [.init(startMinute: 0, item: c)])
        #expect(rules.uses(of: a) == [.desktop, .dark, .rotation])
        #expect(rules.uses(of: b) == [.lockScreen])
        #expect(rules.uses(of: c) == [.rotation, .schedule])
        #expect(rules.uses(of: d).isEmpty)
    }

    @Test func removingAVariantClearsIt() throws {
        let rules = WallpaperRules(wallpaper: a, lockScreen: b, dark: b)
        let edited = try #require(rules.removing(b))
        #expect(edited == WallpaperRules(wallpaper: a))
    }

    @Test func removingTheWallpaperPicksTheReplacementThenARotationItem() throws {
        let rules = WallpaperRules(wallpaper: a, rotation: .init(items: [a, b, c], interval: 60, since: since))
        #expect(try #require(rules.removing(a, replacement: d)).wallpaper == d)
        let edited = try #require(rules.removing(a))
        #expect(edited.wallpaper == b)
        #expect(edited.rotation?.items == [b, c])
    }

    @Test func removingTheLastItemLeavesNothing() {
        #expect(WallpaperRules(wallpaper: a).removing(a) == nil)
        #expect(WallpaperRules(wallpaper: a, lockScreen: a).removing(a) == nil)
    }

    @Test func emptiedRotationsAndSchedulesTurnOff() throws {
        let rules = WallpaperRules(wallpaper: a, rotation: .init(items: [b], interval: 60, since: since), schedule: [.init(startMinute: 60, item: b)])
        let edited = try #require(rules.removing(b))
        #expect(edited.rotation == nil)
        #expect(edited.schedule == nil)
        #expect(edited.wallpaper == a)
    }

    @Test func nextSkipsAhead() {
        let rules = WallpaperRules(wallpaper: a, rotation: .init(items: [a, b, c], interval: 3600, since: since))
        let at = since.addingTimeInterval(10)
        #expect(rules.item(for: .default, appearance: .light, at: at) == a)
        #expect(rules.advanced().item(for: .default, appearance: .light, at: at) == b)
        #expect(rules.advanced().advanced().item(for: .default, appearance: .light, at: at) == c)
        #expect(WallpaperRules(wallpaper: a).advanced() == WallpaperRules(wallpaper: a))
    }

    @Test func shuffleIsTheSameEverywhereAndCoversEveryItem() throws {
        let items = (0..<6).map { _ in UUID() }
        let rotation = WallpaperRules.Rotation(items: items, interval: 60, since: since, shuffle: true)
        let firstPass = (0..<6).compactMap { rotation.item(atStep: $0) }
        #expect(Set(firstPass) == Set(items))
        // Recomputing gives the same order: every surface and restart agrees.
        #expect((0..<6).compactMap { rotation.item(atStep: $0) } == firstPass)
        // A new pass never repeats the item just shown.
        for pass in 1..<20 {
            #expect(rotation.item(atStep: pass * 6) != rotation.item(atStep: pass * 6 - 1))
        }
    }

    @Test func rotationsRoundTripWithTheirExtras() throws {
        let playlist = UUID()
        let rules = WallpaperRules(wallpaper: a, rotation: .init(items: [a, b], interval: 0, since: since, playlist: playlist, shuffle: true, offset: 3))
        let decoded = try #require(KinoraSelection.decode(try KinoraSelection(rules: rules).encoded()))
        #expect(decoded.rules == rules)
        #expect(decoded.rules.rotation?.playlist == playlist)
    }

    @Test func schedulesAreTidied() {
        let tidy = ScheduleEditing.normalized([.init(startMinute: 1200, item: a), .init(startMinute: -5, item: b),
                                               .init(startMinute: 1200, item: c), .init(startMinute: 9999, item: d)])
        #expect(tidy == [.init(startMinute: 0, item: b), .init(startMinute: 1200, item: c), .init(startMinute: 1439, item: d)])
        #expect(WallpaperRules(wallpaper: a).scheduled([]).schedule == nil)
        #expect(WallpaperRules(wallpaper: a).scheduled(ScheduleEditing.dayAndNight(day: a, night: b)).schedule?.count == 2)
    }

    @Test func suggestsTheMiddleOfTheLongestGap() {
        #expect(ScheduleEditing.suggestedStart(after: []) == 7 * 60)
        #expect(ScheduleEditing.suggestedStart(after: [.init(startMinute: 7 * 60, item: a)]) == 19 * 60)
        let both = ScheduleEditing.dayAndNight(day: a, night: b)
        let next = ScheduleEditing.suggestedStart(after: both)
        #expect(!both.map(\.startMinute).contains(next))
        #expect(next % 15 == 0)
    }
}

@Suite struct ContentResolutionTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func showsTheWantedItemWhenItExists() {
        #expect(ContentResolution.item(wanted: a, rules: WallpaperRules(wallpaper: b), fallbacks: [c], exists: { _ in true }) == a)
    }

    @Test func fallsBackThroughTheRulesThenTheLibrary() {
        let rules = WallpaperRules(wallpaper: a, lockScreen: b)
        #expect(ContentResolution.item(wanted: c, rules: rules, fallbacks: [], exists: { $0 == a }) == a)
        #expect(ContentResolution.item(wanted: a, rules: rules, fallbacks: [], exists: { $0 == b }) == b)
        #expect(ContentResolution.item(wanted: a, rules: rules, fallbacks: [c], exists: { $0 == c }) == c)
        #expect(ContentResolution.item(wanted: a, rules: rules, fallbacks: [c], exists: { _ in false }) == nil)
    }
}

@Suite struct AppleAerialsTests {
    let catalog = Data("""
    {"version": 1, "categories": [{"id": "x", "localizedNameKey": "AerialCategoryLandscapes"}],
     "assets": [
       {"id": "4A1B2C3D-0000-4000-8000-000000000001", "accessibilityLabel": "Tahoe Day", "localizedNameKey": "Tahoe_Day", "url-4K-SDR-240FPS": "https://example.invalid/a.mov"},
       {"id": "4A1B2C3D-0000-4000-8000-000000000002", "localizedNameKey": "Sonoma Horizon"},
       {"id": "4A1B2C3D-0000-4000-8000-000000000003", "localizedNameKey": "AerialSonoma_Key"},
       {"id": "4A1B2C3D-0000-4000-8000-000000000004", "accessibilityLabel": "Not downloaded"},
       {"id": "../../etc/passwd", "accessibilityLabel": "Sneaky"},
       {"id": "4A1B2C3D-0000-4000-8000-000000000001", "accessibilityLabel": "Duplicate"},
       {"accessibilityLabel": "No id"}
     ]}
    """.utf8)

    @Test func listsOnlyDownloadedAerialsWithTheirNames() {
        let files: Set<String> = ["4A1B2C3D-0000-4000-8000-000000000001.mov", "4A1B2C3D-0000-4000-8000-000000000002.mov",
                                  "4A1B2C3D-0000-4000-8000-000000000003.mov", "../../etc/passwd.mov"]
        let aerials = AppleAerials.downloaded(catalog: catalog, downloaded: files)
        #expect(aerials.map(\.name) == ["Tahoe Day", "Sonoma Horizon", "Apple Aerial"])
        #expect(aerials[0].fileName == "4A1B2C3D-0000-4000-8000-000000000001.mov")
    }

    @Test func toleratesCatalogsItCannotRead() {
        #expect(AppleAerials.downloaded(catalog: Data("[]".utf8), downloaded: []).isEmpty)
        #expect(AppleAerials.downloaded(catalog: Data("not json".utf8), downloaded: []).isEmpty)
        #expect(AppleAerials.downloaded(catalog: Data(#"{"assets": "nope"}"#.utf8), downloaded: []).isEmpty)
    }

    @Test func refusesIdentifiersThatCouldBePaths() {
        #expect(AppleAerials.isAssetID("4A1B2C3D-0000-4000-8000-000000000001"))
        #expect(!AppleAerials.isAssetID("../x"))
        #expect(!AppleAerials.isAssetID("a/b"))
        #expect(!AppleAerials.isAssetID(""))
        #expect(!AppleAerials.isAssetID("é"))
    }

    @Test func findsTheVideoInWhicheverLocationHasIt() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let legacy = AppleAerials.videoURL(fileName: "x.mov", home: home) { $0.path.contains("idleassetsd") }
        #expect(legacy.path == "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS/x.mov")
        let neither = AppleAerials.videoURL(fileName: "x.mov", home: home) { _ in false }
        #expect(neither.path == "/Users/someone/Library/Application Support/com.apple.wallpaper/aerials/videos/x.mov")
    }
}

@Suite struct UserPauseAndReduceMotionTests {
    @Test func userPauseHoldsEverySurfaceButPreviews() {
        var settings = PlaybackSettings()
        settings.paused = true
        var c = PlaybackConditions()
        c.presentation = .locked
        #expect(PlaybackPolicy.decide(c, settings: settings) == .pause(.paused))
        c.isPreview = true
        #expect(PlaybackPolicy.decide(c, settings: settings) == .play(maxFramesPerSecond: nil))
    }

    @Test func reduceMotionHoldsAStillUnlessTheUserOptsOut() {
        var c = PlaybackConditions()
        c.reduceMotion = true
        c.presentation = .locked
        #expect(PlaybackPolicy.decide(c, settings: PlaybackSettings()) == .pause(.reduceMotion))
        var settings = PlaybackSettings()
        settings.pauseWithReduceMotion = false
        #expect(PlaybackPolicy.decide(c, settings: settings) == .play(maxFramesPerSecond: nil))
    }

    @Test func newSettingsDecodeFromOldFiles() throws {
        let old = try JSONDecoder().decode(PlaybackSettings.self, from: Data(#"{"pauseWhenCovered": false}"#.utf8))
        #expect(!old.paused)
        #expect(old.pauseWithReduceMotion)
        #expect(old.generativeFrameRate == 30)
        let wild = try JSONDecoder().decode(PlaybackSettings.self, from: Data(#"{"generativeFrameRate": 500}"#.utf8))
        #expect(wild.generativeFrameRate == 60)
    }
}
