// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AppKit
import Foundation
import KinoraKit

/// The app's state, made once. The window, the menu bar extra, the Settings window, Shortcuts
/// and `kinora://` links all act on these same objects.
@MainActor final class AppModels {
    static let shared = AppModels()

    let library = LibraryModel()
    let wallpaper = WallpaperController()
    let energy = EnergyMonitor()
    let settings = SettingsModel()
    let gallery = GalleryModel()
    let updates = UpdateChecker()

    private init() {}
}

/// What can be done to Kinora from outside its window: the menu bar, Shortcuts and links.
@MainActor enum KinoraCommands {
    static var models: AppModels { .shared }

    static func pause() { models.settings.playback.paused = true }
    static func resume() { models.settings.playback.paused = false }
    static func togglePause() { models.settings.playback.paused.toggle() }
    static func next() async { await models.wallpaper.next() }

    static func use(_ id: UUID) async -> Bool {
        guard models.library.item(id) != nil else { return false }
        await models.wallpaper.use(itemID: id)
        return true
    }

    /// Battery-first ("rests while you work") or always moving.
    static func setResting(_ resting: Bool) { models.settings.playback.settleAfterUnlock = resting }

    /// `kinora://pause`, `kinora://resume`, `kinora://toggle`, `kinora://next`,
    /// `kinora://use?id=<UUID>`, `kinora://rest` and `kinora://move`. Anything else is ignored.
    static func handle(_ url: URL) async {
        guard url.scheme?.lowercased() == "kinora" else { return }
        switch (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "pause": pause()
        case "resume": resume()
        case "toggle": togglePause()
        case "next": await next()
        case "rest": setResting(true)
        case "move": setResting(false)
        case "use":
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            if let value, let id = UUID(uuidString: value) { _ = await use(id) }
        default: break
        }
    }
}
