// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import SwiftUI

/// The selected wallpaper, what Kinora is doing, and what it costs.
struct Inspector: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @Environment(EnergyMonitor.self) private var energy
    let item: LibraryItem?

    var body: some View {
        Form {
            if let item {
                Section {
                    Thumbnail(url: library.thumbnailURL(item))
                        .aspectRatio(16 / 10, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 10))
                        .listRowInsets(EdgeInsets())
                    Text(item.name).font(.headline)
                    if let stored = item.storedBytes {
                        LabeledContent("On disk") {
                            Text(item.savedBytes > 0
                                 ? "\(stored.formatted(.byteCount(style: .file))), saved \(item.savedBytes.formatted(.byteCount(style: .file)))"
                                 : stored.formatted(.byteCount(style: .file)))
                        }
                    }
                    if wallpaper.currentItem == item.id {
                        Label("On your desktop and Lock Screen", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            Task { await wallpaper.use(item) }
                        } label: {
                            Label("Use as Wallpaper", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(wallpaper.working)
                    }
                }
            }

            if wallpaper.followsSelection, let rules = wallpaper.selection?.rules {
                variants(rules)
            }

            Section("Status") {
                plugInRow
                wallpaperRow
                energyRow
            }

            if wallpaper.canRestore {
                Section {
                    Button("Restore Original Wallpaper") { Task { await wallpaper.restoreOriginal() } }
                        .disabled(wallpaper.working)
                } footer: {
                    Text("Puts back the wallpaper you had before Kinora.")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Lock Screen and dark appearance choices, and the rotation, applied live.
    private func variants(_ rules: WallpaperRules) -> some View {
        Section("Your Wallpaper") {
            Picker("Lock Screen", selection: Binding(get: { rules.lockScreen }, set: { id in
                Task { await wallpaper.change { $0.lockScreen = id } }
            })) {
                Text("Same as Desktop").tag(UUID?.none)
                Divider()
                ForEach(library.items) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Picker("Dark Mode", selection: Binding(get: { rules.dark }, set: { id in
                Task { await wallpaper.change { $0.dark = id } }
            })) {
                Text("Same as Light").tag(UUID?.none)
                Divider()
                ForEach(library.items) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            if let rotation = rules.rotation {
                LabeledContent("Rotating") {
                    HStack {
                        Text("\(rotation.items.count) wallpapers, \(RotationChoice.describe(rotation.interval))")
                            .foregroundStyle(.secondary)
                        Button("Stop") { Task { await wallpaper.change { $0.rotation = nil } } }
                    }
                }
            }
        }
        .disabled(wallpaper.working)
    }

    private var plugInRow: some View {
        LabeledContent("Wallpaper plug-in") {
            switch wallpaper.plugIn {
            case .enabled:
                StatusText("Ready", color: .green)
            case .disabled, .missing:
                HStack {
                    StatusText(wallpaper.plugIn == .missing ? "Not registered" : "Switched off", color: .orange)
                    Button("Turn On") { Task { await wallpaper.repairPlugIn() } }
                }
            case .unknown:
                ProgressView().controlSize(.small)
            }
        }
    }

    private var wallpaperRow: some View {
        LabeledContent("Current wallpaper") {
            if let current = wallpaper.currentItem {
                Text(library.items.first { $0.id == current }?.name ?? "Kinora")
            } else if wallpaper.replacedByOther {
                Text("Another wallpaper").foregroundStyle(.secondary)
            } else {
                Text("Not Kinora").foregroundStyle(.secondary)
            }
        }
    }

    private var energyRow: some View {
        LabeledContent {
            if let reading = energy.reading {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(reading.cpuPercent, format: .number.precision(.fractionLength(1)))% CPU")
                    if let mw = reading.milliwatts {
                        Text("\(mw, format: .number.precision(.fractionLength(0))) mW").foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
            } else {
                Text(energy.running ? "Measuring…" : "Not running").foregroundStyle(.secondary)
            }
        } label: {
            Text("Energy")
            Text("What the plug-in that draws your wallpaper uses right now. Video decoding in the graphics hardware isn't included.")
        }
    }
}

private struct StatusText: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }
}
