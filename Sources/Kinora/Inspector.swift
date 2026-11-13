// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import SwiftUI

/// The selected wallpaper, what Kinora is doing, and what it costs.
struct Inspector: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @Environment(EnergyMonitor.self) private var energy
    @Environment(\.colorScheme) private var colorScheme
    let itemID: UUID?
    @State private var editingSchedule = false

    private var item: LibraryItem? { itemID.flatMap { library.item($0) } }

    var body: some View {
        Form {
            if let item {
                Section {
                    Thumbnail(url: library.thumbnailURL(item))
                        .clipShape(.rect(cornerRadius: 10))
                        .listRowInsets(EdgeInsets())
                    Text(item.name).font(.headline)
                    if item.ownsMedia, let stored = item.storedBytes {
                        LabeledContent("On disk") {
                            Text(item.savedBytes > 0
                                 ? "\(stored.formatted(.byteCount(style: .file))), saved \(item.savedBytes.formatted(.byteCount(style: .file)))"
                                 : stored.formatted(.byteCount(style: .file)))
                        }
                    }
                    if item.kind == .appleAerial {
                        LabeledContent("Source", value: "Apple, from macOS")
                    }
                    if let attribution = item.attribution, item.kind != .appleAerial {
                        AttributionRows(attribution: attribution)
                    }
                    if wallpaper.shownItem(dark: colorScheme == .dark) == item.id {
                        Label(placement(of: item.id), systemImage: "checkmark.circle.fill")
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
        .sheet(isPresented: $editingSchedule) {
            if let fallback = wallpaper.selection?.rules.wallpaper ?? itemID {
                ScheduleEditor(fallback: fallback)
            }
        }
    }

    /// Lock Screen and dark appearance choices, the schedule and the rotation, applied live.
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
            LabeledContent("Time of Day") {
                HStack {
                    Text(scheduleSummary(rules)).foregroundStyle(.secondary)
                    Button("Edit…") { editingSchedule = true }
                }
            }
            if let rotation = rules.rotation {
                LabeledContent("Rotating") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(rotationSummary(rotation)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        HStack {
                            Button("Next") { Task { await wallpaper.next() } }
                                .disabled(rotation.items.count < 2)
                            Button("Stop") { Task { await wallpaper.change { $0.rotation = nil } } }
                        }
                    }
                }
                if rules.schedule != nil {
                    Text("The time-of-day schedule is deciding the desktop, so the rotation waits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(wallpaper.working)
    }

    /// Where the shown item appears: the Lock Screen too, unless it has a wallpaper of its own.
    private func placement(of id: UUID) -> String {
        let lock: UUID? = wallpaper.selection?.rules.lockScreen
        if lock == nil || lock == id { return "On your desktop and Lock Screen" }
        return "On your desktop"
    }

    private func scheduleSummary(_ rules: WallpaperRules) -> String {
        guard let schedule = rules.schedule, !schedule.isEmpty else { return "Off" }
        return schedule.count == 1 ? "1 change a day" : "\(schedule.count) changes a day"
    }

    private func rotationSummary(_ rotation: WallpaperRules.Rotation) -> String {
        let source = rotation.playlist.flatMap { library.playlist($0)?.name }.map { "“\($0)”" } ?? "\(rotation.items.count) wallpapers"
        let order = rotation.shuffle == true ? ", shuffled" : ""
        return "\(source)\(order), \(RotationChoice.describe(rotation.interval))"
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
            if let current = wallpaper.shownItem(dark: colorScheme == .dark) {
                Text(name(of: current))
            } else if wallpaper.replacedByOther {
                Text("Another wallpaper").foregroundStyle(.secondary)
            } else {
                Text("Not Kinora").foregroundStyle(.secondary)
            }
        }
    }

    private func name(of id: UUID) -> String {
        if let item = library.item(id) { return item.name }
        return "Kinora"
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

/// Who made a wallpaper and under which license, with a link to the source.
struct AttributionRows: View {
    let attribution: LibraryItem.Attribution

    var body: some View {
        if let author = attribution.author {
            LabeledContent("By", value: author)
        }
        if let license = attribution.license {
            LabeledContent("License", value: license)
        }
        if let source = attribution.source, source.scheme == "https" {
            Link("View Source", destination: source)
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
