// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

/// Stores shaped like the ones seen on macOS 27.0.1: `Index.plist` with an aerial chosen for all
/// spaces and displays, and a variant with a `Linked` entry and a per-display node.
enum StoreFixtures {
    static let aerials = "com.apple.wallpaper.choice.aerials"
    static let then = Date(timeIntervalSince1970: 1_790_000_000)

    static func entry(_ provider: String) -> [String: Any] {
        ["Content": ["Choices": [["Provider": provider, "Configuration": Data("{}".utf8), "Files": [Any]()]],
                     "EncodedOptionValues": Data(), "Shuffle": "$null"],
         "LastSet": then, "LastUse": then]
    }

    static func node(desktop: String, idle: String = aerials, linked: String? = nil) -> [String: Any] {
        var node: [String: Any] = ["Desktop": entry(desktop), "Idle": entry(idle), "Type": "individual"]
        if let linked { node["Linked"] = entry(linked) }
        return node
    }

    static var thisMac: [String: Any] {
        ["AllSpacesAndDisplays": node(desktop: aerials), "Displays": [String: Any](), "Spaces": [String: Any](),
         "SystemDefault": node(desktop: aerials)]
    }

    static var linkedWithDisplay: [String: Any] {
        ["AllSpacesAndDisplays": node(desktop: aerials, linked: aerials),
         "Displays": ["37D8832A-2D66-02CA-B9F7-8F30A301B230": node(desktop: "com.apple.wallpaper.choice.image")],
         "Spaces": [String: Any](), "SystemDefault": node(desktop: aerials)]
    }

    static func provider(_ store: [String: Any], _ path: String...) -> String? {
        var node: Any? = store
        for key in path { node = (node as? [String: Any])?[key] }
        return (((node as? [String: Any])?["Content"] as? [String: Any])?["Choices"] as? [[String: Any]])?.first?["Provider"] as? String
    }
}

@Suite struct WallpaperStoreEditorTests {
    let configuration = ChoiceConfiguration(wallpaper: UUID()).encoded()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func selectsKinoraForTheDesktopOfEveryScope() {
        let edited = WallpaperStoreEditor.selectingKinora(StoreFixtures.linkedWithDisplay, configuration: configuration, now: now)
        #expect(StoreFixtures.provider(edited, "AllSpacesAndDisplays", "Desktop") == KinoraIdentity.providerID)
        #expect(StoreFixtures.provider(edited, "AllSpacesAndDisplays", "Linked") == KinoraIdentity.providerID)
        #expect(StoreFixtures.provider(edited, "Displays", "37D8832A-2D66-02CA-B9F7-8F30A301B230", "Desktop") == KinoraIdentity.providerID)
        #expect(WallpaperStoreEditor.kinoraIsSelected(edited))
        #expect(WallpaperStoreEditor.kinoraConfiguration(edited) == configuration)
    }

    @Test func leavesTheScreenSaverAndSystemDefaultAlone() {
        let edited = WallpaperStoreEditor.selectingKinora(StoreFixtures.thisMac, configuration: configuration, now: now)
        #expect(StoreFixtures.provider(edited, "AllSpacesAndDisplays", "Idle") == StoreFixtures.aerials)
        #expect(StoreFixtures.provider(edited, "SystemDefault", "Desktop") == StoreFixtures.aerials)
        #expect((edited["AllSpacesAndDisplays"] as? [String: Any])?["Type"] as? String == "individual")
    }

    @Test func stampsLastSetButKeepsLastUse() {
        let edited = WallpaperStoreEditor.selectingKinora(StoreFixtures.thisMac, configuration: configuration, now: now)
        let desktop = (edited["AllSpacesAndDisplays"] as? [String: Any])?["Desktop"] as? [String: Any]
        #expect(desktop?["LastSet"] as? Date == now)
        #expect(desktop?["LastUse"] as? Date == StoreFixtures.then)
    }

    @Test func reportsAnotherWallpaperAsNotKinora() {
        #expect(!WallpaperStoreEditor.kinoraIsSelected(StoreFixtures.thisMac))
        #expect(WallpaperStoreEditor.kinoraConfiguration(StoreFixtures.thisMac) == nil)
        #expect(WallpaperStoreEditor.desktopProviders(StoreFixtures.thisMac) == [StoreFixtures.aerials])
    }

    @Test func partlyKinoraIsNotSelected() {
        // Another writer, for example System Settings, changed one display back.
        var store = WallpaperStoreEditor.selectingKinora(StoreFixtures.linkedWithDisplay, configuration: configuration, now: now)
        var displays = store["Displays"] as! [String: Any]
        displays["37D8832A-2D66-02CA-B9F7-8F30A301B230"] = StoreFixtures.node(desktop: StoreFixtures.aerials)
        store["Displays"] = displays
        #expect(!WallpaperStoreEditor.kinoraIsSelected(store))
    }

    @Test func anEmptyStoreHasNothingSelected() {
        #expect(!WallpaperStoreEditor.kinoraIsSelected([:]))
        #expect(WallpaperStoreEditor.selectingKinora([:], configuration: configuration, now: now).isEmpty)
    }
}

@Suite struct WallpaperStoreFilesTests {
    let root: URL
    let files: WallpaperStoreFiles
    let configuration = ChoiceConfiguration(wallpaper: UUID()).encoded()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kinora-store-\(UUID().uuidString)")
        files = WallpaperStoreFiles(storeFolder: root.appendingPathComponent("Store"), backupFolder: root.appendingPathComponent("Backups"))
        try FileManager.default.createDirectory(at: files.storeFolder, withIntermediateDirectories: true)
    }

    func writeStore(_ store: [String: Any], name: String = "Index.plist") throws {
        let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        try data.write(to: files.storeFolder.appendingPathComponent(name))
    }

    func select() throws {
        try files.apply { WallpaperStoreEditor.selectingKinora($0, configuration: configuration, now: Date()) }
    }

    @Test func appliesToEveryStoreFileAndBacksUpFirst() throws {
        try writeStore(StoreFixtures.thisMac)
        try writeStore(StoreFixtures.thisMac, name: "Index_v2.plist")
        let written = try files.apply { WallpaperStoreEditor.selectingKinora($0, configuration: configuration, now: Date()) }
        #expect(written.map(\.lastPathComponent) == ["Index.plist", "Index_v2.plist"])
        for url in written { #expect(WallpaperStoreEditor.kinoraIsSelected(try files.read(url))) }
        #expect(files.hasOriginalBackup)
    }

    @Test func theOriginalBackupSurvivesLaterWrites() throws {
        try writeStore(StoreFixtures.thisMac)
        try select()
        try select()
        let original = try files.read(files.backup("original", "Index.plist"))
        #expect(!WallpaperStoreEditor.kinoraIsSelected(original))
        let previous = try files.read(files.backup("previous", "Index.plist"))
        #expect(WallpaperStoreEditor.kinoraIsSelected(previous))
    }

    @Test func restoresTheOriginal() throws {
        try writeStore(StoreFixtures.thisMac)
        try select()
        #expect(try files.restoreOriginal())
        #expect(WallpaperStoreEditor.desktopProviders(try files.readPrimary()) == [StoreFixtures.aerials])
    }

    @Test func refusesWhenThereIsNoStore() {
        #expect(throws: WallpaperStoreError.noStore) { try select() }
        #expect(!files.hasOriginalBackup)
    }

    @Test func anUnreadableStoreStopsTheChangeBeforeAnyWrite() throws {
        try writeStore(StoreFixtures.thisMac)
        try Data("not a plist".utf8).write(to: files.storeFolder.appendingPathComponent("Index_v2.plist"))
        #expect(throws: WallpaperStoreError.unreadable("Index_v2.plist")) { try select() }
        #expect(!WallpaperStoreEditor.kinoraIsSelected(try files.readPrimary()))
        #expect(!files.hasOriginalBackup)
    }
}

@Suite struct LibraryTests {
    @Test func indexRoundTrips() throws {
        let item = LibraryItem(name: "Ocean", kind: .video, media: "a.mov", thumbnail: "a.png", addedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let index = LibraryIndex(items: [item])
        #expect(LibraryIndex.decode(try index.encoded()) == index)
    }

    @Test func skipsItemsItCannotRead() throws {
        let json = #"{"version":1,"items":[{"id":"6F1C0C1E-8E1D-4B8A-9B8E-2B4F5D6A7C8D","name":"Ocean","kind":"video","media":"a.mov","thumbnail":"a.png","addedAt":"2026-11-12T10:00:00Z"},{"id":"x","kind":"hologram"}]}"#
        let index = try #require(LibraryIndex.decode(Data(json.utf8)))
        #expect(index.items.map(\.name) == ["Ocean"])
    }

    @Test func locationIsUnderTheRealHome() {
        let location = LibraryLocation(home: URL(fileURLWithPath: "/Users/someone"))
        #expect(location.root.path == "/Users/someone/Library/Application Support/Kinora")
        #expect(location.index.lastPathComponent == "library.json")
        #expect(!realHomeDirectory().path.contains("/Containers/"))
    }
}

@Suite struct LibrarySafetyTests {
    @Test func dropsItemsThatNamePathsInsteadOfFiles() throws {
        func item(_ media: String, _ thumb: String) -> String {
            #"{"id":"\#(UUID().uuidString)","name":"x","kind":"video","media":"\#(media)","thumbnail":"\#(thumb)","addedAt":"2026-11-12T10:00:00Z"}"#
        }
        let json = #"{"version":1,"items":[\#(item("ok.mov", "ok.png")),\#(item("../../.ssh/id_rsa", "a.png")),\#(item("a.mov", "/etc/passwd")),\#(item("..", "a.png")),\#(item("", "a.png"))]}"#
        let index = try #require(LibraryIndex.decode(Data(json.utf8)))
        #expect(index.items.map(\.media) == ["ok.mov"])
    }

    @Test func plainFileNames() {
        #expect(isPlainFileName("6F1C0C1E.mov"))
        #expect(!isPlainFileName("a/b.mov"))
        #expect(!isPlainFileName(".."))
        #expect(!isPlainFileName("~root"))
    }
}
