// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

@Suite struct SettingsViewModelTests {
    let item = UUID(uuidString: "6F1C0C1E-8E1D-4B8A-9B8E-2B4F5D6A7C8D")!
    var tile: SettingsTile {
        SettingsTile(id: item.uuidString, name: "Ocean", thumbnail: URL(fileURLWithPath: "/tmp/ocean.png"),
                     configuration: ChoiceConfiguration(wallpaper: item))
    }

    func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func listsTilesForTheDesktopAndTheScreenSaver() throws {
        let root = try object(SettingsViewModels.json(groupName: "Kinora", tiles: [tile]))
        for key in ["desktop", "screenSaver"] {
            let model = try #require(root[key] as? [String: Any])
            let groups = try #require(model["groups"] as? [[String: Any]])
            #expect(groups.count == 1)
            #expect(groups[0]["localizedName"] as? String == "Kinora")
            let items = try #require(groups[0]["items"] as? [[String: Any]])
            #expect(items.count == 1)
            #expect(items[0]["localizedName"] as? String == "Ocean")
        }
    }

    @Test func choiceNamesThePlugInAsProviderAndCarriesTheConfiguration() throws {
        let root = try object(SettingsViewModels.json(groupName: "Kinora", tiles: [tile]))
        let model = try #require(root["desktop"] as? [String: Any])
        let item = try #require(((model["groups"] as? [[String: Any]])?.first?["items"] as? [[String: Any]])?.first)
        let descriptor = try #require(((item["choice"] as? [String: Any])?["id"] as? [String: Any])?["descriptor"] as? [String: Any])
        #expect(descriptor["provider"] as? String == "io.github.sky-walkerx.kinora.wallpaper")
        let configuration = try #require((descriptor["configuration"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(ChoiceConfiguration.decode(configuration)?.wallpaper == self.item)
    }

    @Test func casesWithoutPayloadUseSwiftsCodableShape() throws {
        let root = try object(SettingsViewModels.json(groupName: "Kinora", tiles: [tile]))
        let model = try #require(root["desktop"] as? [String: Any])
        #expect((model["refreshPolicy"] as? [String: Any])?.keys.first == "default")
        let item = try #require(((model["groups"] as? [[String: Any]])?.first?["items"] as? [[String: Any]])?.first)
        #expect((item["contentBadge"] as? [String: Any])?.keys.first == "video")
    }

    @Test func anEmptyLibraryListsNoGroup() throws {
        let root = try object(SettingsViewModels.json(groupName: "Kinora", tiles: []))
        #expect(((root["desktop"] as? [String: Any])?["groups"] as? [Any])?.isEmpty == true)
    }

    /// Contract test: Apple's own decoder, from this Mac's WallpaperExtensionKit, must accept
    /// what we send. It fails when a macOS update changes the format, instead of System
    /// Settings silently dropping Kinora's tiles. Skipped where the private class is absent.
    @Test(.enabled(if: AppleWallpaperDecoder.isAvailable))
    func applesDecoderAcceptsTheViewModels() {
        let data = SettingsViewModels.json(groupName: "Kinora", tiles: [tile, tile])
        #expect(AppleWallpaperDecoder.accepts(data, className: "WallpaperSettingsViewModelsXPC", key: "WallpaperSettingsViewModels"))
    }

    @Test(.enabled(if: AppleWallpaperDecoder.isAvailable))
    func applesDecoderRejectsAWrongShape() {
        let wrong = Data(#"{"desktop": {"groups": "nope"}}"#.utf8)
        #expect(!AppleWallpaperDecoder.accepts(wrong, className: "WallpaperSettingsViewModelsXPC", key: "WallpaperSettingsViewModels"))
    }
}

@Suite struct ChoiceConfigurationTests {
    let desk = UUID(), lock = UUID()

    @Test func roundTrips() {
        let configuration = ChoiceConfiguration(wallpaper: desk, lockScreen: lock)
        #expect(ChoiceConfiguration.decode(configuration.encoded()) == configuration)
    }

    @Test func picksTheLockScreenItemOnlyWhenLocked() {
        let configuration = ChoiceConfiguration(wallpaper: desk, lockScreen: lock)
        #expect(configuration.item(for: .locked) == lock)
        #expect(configuration.item(for: .default) == desk)
        #expect(configuration.item(for: .idle) == desk)
        #expect(ChoiceConfiguration(wallpaper: desk).item(for: .locked) == desk)
    }

    @Test func ignoresBytesKinoraDidNotWrite() {
        #expect(ChoiceConfiguration.decode(Data(#"{"assetID":"86E89C23"}"#.utf8)) == nil)
        #expect(ChoiceConfiguration.decode(Data()) == nil)
        #expect(ChoiceConfiguration.decode(nil) == nil)
    }
}
