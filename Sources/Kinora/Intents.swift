// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AppIntents
import Foundation
import KinoraKit

// Shortcuts actions. They act on the running app's state (AppModels), the same as the menu
// bar extra. The same commands are available as kinora:// links for Shortcuts' "Open URLs".

struct PauseWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Wallpapers"
    static let description = IntentDescription("Holds every Kinora wallpaper on its current frame until you resume.")

    @MainActor func perform() async throws -> some IntentResult {
        KinoraCommands.pause()
        return .result()
    }
}

struct ResumeWallpapersIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Wallpapers"
    static let description = IntentDescription("Lets Kinora's wallpapers move again, following your battery rules.")

    @MainActor func perform() async throws -> some IntentResult {
        KinoraCommands.resume()
        return .result()
    }
}

struct NextWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Wallpaper"
    static let description = IntentDescription("Moves a rotation or playlist on to its next wallpaper.")

    @MainActor func perform() async throws -> some IntentResult {
        await KinoraCommands.next()
        return .result()
    }
}

struct SetDesktopMotionIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Desktop Motion"
    static let description = IntentDescription("Chooses whether the desktop rests while you work, which uses the least battery, or always moves.")

    @Parameter(title: "Rest While You Work", default: true)
    var resting: Bool

    @MainActor func perform() async throws -> some IntentResult {
        KinoraCommands.setResting(resting)
        return .result()
    }
}

struct KinoraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PauseWallpapersIntent(), phrases: ["Pause \(.applicationName) wallpapers"],
                    shortTitle: "Pause Wallpapers", systemImageName: "pause.fill")
        AppShortcut(intent: ResumeWallpapersIntent(), phrases: ["Resume \(.applicationName) wallpapers"],
                    shortTitle: "Resume Wallpapers", systemImageName: "play.fill")
        AppShortcut(intent: NextWallpaperIntent(), phrases: ["Next \(.applicationName) wallpaper"],
                    shortTitle: "Next Wallpaper", systemImageName: "forward.fill")
    }
}
