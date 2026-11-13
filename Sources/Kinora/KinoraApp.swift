// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AppKit
import KinoraKit
import SwiftUI

/// SwiftUI declares its own `LibraryItem`; in this app the name means Kinora's.
typealias LibraryItem = KinoraKit.LibraryItem

/// Receives videos opened with Kinora from Finder or dropped on its Dock icon.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the library exists; until then, opened videos wait in `pending`.
    var openVideos: (([URL]) -> Void)?
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let openVideos { openVideos(urls) } else { pending.append(contentsOf: urls) }
    }

    /// Videos opened before the window existed.
    func takePending() -> [URL] {
        defer { pending.removeAll() }
        return pending
    }
}

@main
struct KinoraApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var library = LibraryModel()
    @State private var wallpaper = WallpaperController()
    @State private var energy = EnergyMonitor()
    @State private var settings = SettingsModel()

    var body: some Scene {
        Window("Kinora", id: "library") {
            ContentView()
                .environment(library)
                .environment(wallpaper)
                .environment(energy)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    appDelegate.openVideos = { urls in Task { await library.importVideos(urls) } }
                    let early = appDelegate.takePending()
                    if !early.isEmpty { await library.importVideos(early) }
                    wallpaper.refresh()
                    wallpaper.watchStore()
                    await wallpaper.repairPlugIn()
                    energy.start()
                    // System Settings lists originals once their thumbnails exist.
                    if await OriginalThumbnails.ensure(in: library.location.thumbnailFolder) { LibraryModel.postLibraryChanged() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // System Settings or another app may have changed the wallpaper meanwhile.
                    wallpaper.refresh()
                }
        }
        .defaultSize(width: 980, height: 620)

        Settings {
            SettingsView().environment(settings)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Wallpaper") {
                Toggle("Pause Wallpapers", isOn: Binding(get: { settings.playback.paused }, set: { settings.playback.paused = $0 }))
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Next Wallpaper") { Task { await wallpaper.next() } }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(wallpaper.selection?.rules.rotation == nil)
            }
        }
    }
}
