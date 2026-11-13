// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import Observation
import ServiceManagement
import SwiftUI

/// The playback rules, saved where the plug-in reads them.
@MainActor @Observable final class SettingsModel {
    var playback: PlaybackSettings {
        didSet { if playback != oldValue { save() } }
    }

    private let location: LibraryLocation

    init(location: LibraryLocation = .current) {
        self.location = location
        playback = Self.read(location) ?? PlaybackSettings()
    }

    /// Picks up changes another copy of Kinora or a script made to the settings file.
    func reload() {
        if let fresh = Self.read(location), fresh != playback { playback = fresh }
    }

    private static func read(_ location: LibraryLocation) -> PlaybackSettings? {
        (try? Data(contentsOf: location.settings)).flatMap { try? JSONDecoder().decode(PlaybackSettings.self, from: $0) }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(playback).write(to: location.settings, options: .atomic)
            LibraryModel.postLibraryChanged()
        } catch {
            // The previous rules stay in force; nothing else depends on this write.
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Playback & Battery", systemImage: "battery.75percent") { PlaybackSettingsView() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(UpdateChecker.self) private var updates
    @AppStorage("showGallery") private var showGallery = true
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage(UpdateChecker.automaticKey) private var checkAutomatically = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Kinora at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Toggle("Show Kinora in the menu bar", isOn: $showMenuBarExtra)
            } footer: {
                Text(loginError ?? "Your wallpaper keeps playing without Kinora open. Open it at login for the menu bar controls.")
            }
            Section {
                Toggle("Show the gallery", isOn: $showGallery)
            } header: {
                Text("Gallery")
            } footer: {
                Text("Kinora goes online only when you browse the gallery, download from it or check for updates. It has no account, no analytics and no tracking.")
            }
            Section {
                Toggle("Check for updates once a week", isOn: $checkAutomatically)
                LabeledContent("Kinora \(updates.currentVersion)") {
                    HStack {
                        updateStatus
                        Button("Check Now") { Task { await updates.check() } }
                            .disabled(updates.state == .checking)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Kinora only tells you a new version exists and links to its release page; it never downloads or installs anything by itself.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var updateStatus: some View {
        switch updates.state {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Text("Up to date").foregroundStyle(.secondary)
        case .noReleases: Text("No releases yet").foregroundStyle(.secondary)
        case .failed: Text("Couldn't check").foregroundStyle(.secondary)
        case .available(let version, let page): Link("Kinora \(version) is available", destination: page)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS didn't allow that: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct PlaybackSettingsView: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Desktop", selection: $settings.playback.settleAfterUnlock) {
                    Text("Rests while you work").tag(true)
                    Text("Always moving").tag(false)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(settings.playback.settleAfterUnlock
                     ? "Moves on the Lock Screen, for a few seconds after you unlock, and whenever your desktop is clear. Uses the least battery."
                     : "Moves whenever you can see it.")
            }

            Section("Saving Power") {
                Toggle("Pause when windows cover the desktop", isOn: $settings.playback.pauseWhenCovered)
                Picker("On battery", selection: $settings.playback.batteryFrameCap) {
                    Text("Limit to 30 frames a second").tag(Int?.some(30))
                    Text("Full frame rate").tag(Int?.none)
                }
                Toggle("Pause in Low Power Mode", isOn: $settings.playback.pauseInLowPowerMode)
                Toggle("Pause when your Mac is hot", isOn: $settings.playback.pauseWhenHot)
                Picker("Kinora Originals", selection: $settings.playback.generativeFrameRate) {
                    Text("Up to 30 frames a second").tag(30)
                    Text("Up to 20 frames a second").tag(20)
                    Text("Up to 10 frames a second").tag(10)
                }
            }

            Section {
                Toggle("Hold a still when Reduce Motion is on", isOn: $settings.playback.pauseWithReduceMotion)
                Toggle("Pause all wallpapers", isOn: $settings.playback.paused)
            } header: {
                Text("Motion")
            } footer: {
                Text("Reduce Motion is in System Settings › Accessibility › Display. Paused wallpapers hold their current frame until you resume them.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AdvancedSettings: View {
    @Environment(WallpaperController.self) private var wallpaper
    @State private var confirmingRemoval = false
    @State private var deleteLibrary = false
    @State private var removal: Uninstaller.Outcome?
    @State private var exporting = false

    var body: some View {
        Form {
            Section("Repair") {
                LabeledContent("Wallpaper plug-in") {
                    HStack {
                        Text(String(describing: wallpaper.plugIn).capitalized).foregroundStyle(.secondary)
                        Button("Repair") { Task { await wallpaper.repairPlugIn() } }
                    }
                }
                Button("Restore Original Wallpaper") { Task { await wallpaper.restoreOriginal() } }
                    .disabled(!wallpaper.canRestore || wallpaper.working)
            }
            Section {
                Button(exporting ? "Preparing…" : "Save Diagnostics…") {
                    exporting = true
                    Task { await Diagnostics.export(); exporting = false }
                }
                .disabled(exporting)
            } footer: {
                Text("A text file of versions, settings and recent log messages, for a bug report. It names no files or wallpapers, and Kinora never sends it anywhere.")
            }
            Section {
                Toggle("Also delete my Kinora library", isOn: $deleteLibrary)
                Button("Remove Kinora…", role: .destructive) { confirmingRemoval = true }
            } header: {
                Text("Uninstall")
            } footer: {
                Text(removalSummary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Remove Kinora from this Mac?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { removal = await Uninstaller.run(deleteLibrary: deleteLibrary) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteLibrary
                 ? "Kinora puts back the wallpaper you had, takes its section out of System Settings and deletes its library. Your original videos and photos are not touched."
                 : "Kinora puts back the wallpaper you had and takes its section out of System Settings. Your library stays, in case you come back.")
        }
    }

    private var removalSummary: String {
        guard let removal else {
            return "Puts back the wallpaper you had before Kinora and removes the plug-in, so nothing is left in System Settings. Then drag Kinora to the Bin."
        }
        var parts: [String] = []
        if removal.restoredWallpaper { parts.append("Your original wallpaper is back.") }
        parts.append(removal.unregistered ? "The plug-in is removed." : "macOS still lists the plug-in; it goes once you delete the app.")
        if removal.deletedLibrary { parts.append("The library is deleted.") }
        parts.append("Now quit Kinora and drag it to the Bin.")
        return parts.joined(separator: " ")
    }
}

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: PackageInstaller.kinoraVersion)
                Text("Kinora is free software: you can redistribute it and modify it under the terms of the GNU General Public License, version 3 or later. It comes with no warranty.")
                Link("Source code and license", destination: URL(string: "https://github.com/Sky-walkerX/kinora")!)
            }
            Section("Credits") {
                Text("The build and signing scripts are adapted from Vorssaint, GPL-3.0-or-later. Lively's wallpaper format is read following Lively's GPL-3.0 source. Kinora is not affiliated with Apple, Lively or Wallpaper Engine.")
                Text("Apple's aerials belong to Apple; Kinora plays the ones macOS downloaded and never copies or shares them.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
