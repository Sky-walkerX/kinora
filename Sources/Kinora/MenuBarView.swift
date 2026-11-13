// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import SwiftUI

/// The menu bar extra: pause or resume, next in a rotation, what it costs, and a quick switch.
struct MenuBarView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @Environment(EnergyMonitor.self) private var energy
    @Environment(SettingsModel.self) private var settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(settings.playback.paused ? "Resume Wallpapers" : "Pause Wallpapers") { KinoraCommands.togglePause() }
        Button("Next Wallpaper") { Task { await KinoraCommands.next() } }
            .disabled(wallpaper.selection?.rules.rotation == nil)
        Divider()
        Text(costLine)
        if let shown = wallpaper.currentItem.flatMap({ library.item($0) }) {
            Text("Showing \(shown.name)")
        }
        Menu("Use as Wallpaper") {
            ForEach(library.items.prefix(20)) { item in
                Button(item.name) { Task { await wallpaper.use(item) } }
            }
            if !library.items.isEmpty { Divider() }
            ForEach(KinoraOriginals.all) { original in
                Button(original.name) { Task { await wallpaper.use(itemID: original.id) } }
            }
        }
        if !library.playlists.isEmpty {
            Menu("Play Playlist") {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) { Task { await wallpaper.play(playlist, every: 3600, shuffle: false) } }
                        .disabled(playlist.items.isEmpty)
                }
            }
        }
        Picker("Desktop", selection: Binding(get: { settings.playback.settleAfterUnlock }, set: { resting in KinoraCommands.setResting(resting) })) {
            Text("Rests While You Work").tag(true)
            Text("Always Moving").tag(false)
        }
        Divider()
        Button("Open Kinora") {
            NSApp.activate()
            openWindow(id: "library")
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Kinora") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var costLine: String {
        guard let reading = energy.reading else { return energy.running ? "Measuring…" : "Plug-in not running" }
        let cpu = reading.cpuPercent.formatted(.number.precision(.fractionLength(1)))
        return "Using \(cpu)% CPU"
    }
}
