// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// One wallpaper as a tile in System Settings › Wallpaper.
public struct SettingsTile: Equatable, Sendable {
    public var id: String
    public var name: String
    public var thumbnail: URL
    public var configuration: ChoiceConfiguration
    public var isVideo: Bool

    public init(id: String, name: String, thumbnail: URL, configuration: ChoiceConfiguration, isVideo: Bool = true) {
        self.id = id
        self.name = name
        self.thumbnail = thumbnail
        self.configuration = configuration
        self.isVideo = isVideo
    }
}

/// Builds the JSON System Settings reads to list a plug-in's wallpapers. The shape mirrors
/// WallpaperTypes' `WallpaperSettingsViewModels` on macOS 27 (see docs/spikes); enum cases
/// without payload are written the way Swift's synthesized Codable writes them, `{"name": {}}`.
/// A section of tiles in System Settings.
public struct SettingsGroup: Equatable, Sendable {
    public var id: String
    public var name: String
    public var tiles: [SettingsTile]

    public init(id: String, name: String, tiles: [SettingsTile]) {
        self.id = id
        self.name = name
        self.tiles = tiles
    }
}

public enum SettingsViewModels {
    public static let groupID = "io.github.sky-walkerx.kinora.library"
    public static let originalsGroupID = "io.github.sky-walkerx.kinora.originals"

    public static func json(groupName: String, tiles: [SettingsTile]) -> Data {
        json(groups: [SettingsGroup(id: groupID, name: groupName, tiles: tiles)])
    }

    /// Groups without tiles are left out.
    public static func json(groups: [SettingsGroup]) -> Data {
        let model = viewModel(groups: groups)
        let root: [String: Any] = ["desktop": model, "screenSaver": model]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func viewModel(groupName: String, tiles: [SettingsTile]) -> [String: Any] {
        viewModel(groups: [SettingsGroup(id: groupID, name: groupName, tiles: tiles)])
    }

    static func viewModel(groups: [SettingsGroup]) -> [String: Any] {
        let built = groups.filter { !$0.tiles.isEmpty }.enumerated().map { order, group -> [String: Any] in
            let items = group.tiles.enumerated().map { index, tile in item(tile, sortOrder: index) }
            return [
                "id": ["id": group.id],
                "localizedName": group.name,
                "disposability": unit("none"),
                "sortID": ["id": order == 0 ? "kinora" : "kinora.\(order)"],
                "shouldHideItemLabels": false,
                "sortOrder": order,
                "items": items,
            ]
        }
        return ["groups": built, "refreshPolicy": unit("default"), "isModificationDisabled": false]
    }

    static func item(_ tile: SettingsTile, sortOrder: Int) -> [String: Any] {
        let thumbnail: [String: Any] = ["image": ["url": tile.thumbnail.absoluteString]]
        let choice: [String: Any] = [
            "id": ["descriptor": [
                "provider": KinoraIdentity.providerID,
                "files": [String](),
                "configuration": tile.configuration.encoded().base64EncodedString(),
            ]],
            "localizedDescription": tile.name,
            "thumbnail": thumbnail,
            "isDownloaded": true,
            "options": [Any](),
        ]
        return [
            "id": ["id": tile.id],
            "localizedName": tile.name,
            "thumbnail": thumbnail,
            "choice": choice,
            "contentBadge": unit(tile.isVideo ? "video" : "none"),
            "showInTopLevel": true,
            "sortOrder": sortOrder,
            "disposability": unit("none"),
        ]
    }

    static func unit(_ name: String) -> [String: Any] { [name: [String: Any]()] }
}
