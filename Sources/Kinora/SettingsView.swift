// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import Observation
import SwiftUI

/// The playback rules, saved where the plug-in reads them.
@MainActor @Observable final class SettingsModel {
    var playback: PlaybackSettings {
        didSet { if playback != oldValue { save() } }
    }

    private let location: LibraryLocation

    init(location: LibraryLocation = .current) {
        self.location = location
        playback = (try? Data(contentsOf: location.settings)).flatMap { try? JSONDecoder().decode(PlaybackSettings.self, from: $0) }
            ?? PlaybackSettings()
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
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
