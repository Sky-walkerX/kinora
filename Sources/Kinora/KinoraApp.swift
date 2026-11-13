// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AppKit
import KinoraKit
import SwiftUI

/// SwiftUI declares its own `LibraryItem`; in this app the name means Kinora's.
typealias LibraryItem = KinoraKit.LibraryItem

/// Receives files opened with Kinora from Finder or dropped on its Dock icon, and kinora:// links.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the library exists; until then, opened videos wait in `pending`.
    var openVideos: (([URL]) -> Void)?
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        // kinora:// links are commands, from Shortcuts' "Open URLs" or a script.
        let commands = urls.filter { $0.scheme?.lowercased() == "kinora" }
        for url in commands { Task { await KinoraCommands.handle(url) } }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let openVideos { openVideos(files) } else { pending.append(contentsOf: files) }
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
    private let models = AppModels.shared
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @State private var onboarding = false

    var body: some Scene {
        Window("Kinora", id: "library") {
            ContentView()
                .environment(models.library)
                .environment(models.wallpaper)
                .environment(models.energy)
                .environment(models.gallery)
                .environment(models.settings)
                .frame(minWidth: 860, minHeight: 520)
                .task {
                    appDelegate.openVideos = { urls in Task { await models.library.importVideos(urls) } }
                    let early = appDelegate.takePending()
                    if !early.isEmpty { await models.library.importVideos(early) }
                    models.wallpaper.refresh()
                    models.wallpaper.watchStore()
                    await models.wallpaper.repairPlugIn()
                    models.energy.start()
                    if !onboarded { onboarding = true }
                    // System Settings lists originals once their thumbnails exist.
                    if await OriginalThumbnails.ensure(in: models.library.location.thumbnailFolder) { LibraryModel.postLibraryChanged() }
                    await models.updates.checkIfDue()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // System Settings or another app may have changed the wallpaper meanwhile.
                    models.wallpaper.refresh()
                    models.settings.reload()
                }
                .sheet(isPresented: $onboarding) {
                    OnboardingView().environment(models.wallpaper)
                }
        }
        .defaultSize(width: 1040, height: 660)

        MenuBarExtra("Kinora", systemImage: models.settings.playback.paused ? "pause.rectangle" : "play.rectangle", isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(models.library)
                .environment(models.wallpaper)
                .environment(models.energy)
                .environment(models.settings)
        }

        Settings {
            SettingsView()
                .environment(models.settings)
                .environment(models.wallpaper)
                .environment(models.updates)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Wallpaper") {
                Toggle("Pause Wallpapers", isOn: Binding(get: { models.settings.playback.paused }, set: { models.settings.playback.paused = $0 }))
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Next Wallpaper") { Task { await models.wallpaper.next() } }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(models.wallpaper.selection?.rules.rotation == nil)
            }
            CommandGroup(after: .help) {
                Button("Show Welcome") { onboarding = true }
            }
        }
    }
}
