// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import KinoraRender
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
            if let item, item.kind == .original, let original = KinoraOriginals.original(item.id) {
                OriginalInspectorSection(original: original)
            } else if let item {
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
                        if let showing = wallpaper.displaysShowing(item.id, dark: colorScheme == .dark), !showing.isEmpty {
                            Label("On \(ListFormatter.localizedString(byJoining: showing.map(\.name)))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
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

            if let item, item.kind == .livingPhoto {
                LivingPhotoRemakeSection(item: item).id(item.id)
            }

            if wallpaper.followsSelection, let rules = wallpaper.selection?.rules {
                variants(rules)
                if wallpaper.displays.count > 1 || !wallpaper.disconnectedChoices.isEmpty {
                    displaysSection
                }
            } else if let current = wallpaper.currentItem {
                // Picked in System Settings: one wallpaper, no variants until Kinora manages it.
                Section {
                    Button("Manage in Kinora") { Task { await wallpaper.use(itemID: current) } }
                        .disabled(wallpaper.working)
                } header: {
                    Text("Your Wallpaper")
                } footer: {
                    Text("You picked this wallpaper in System Settings. To give the Lock Screen or Dark Mode their own wallpaper, or to rotate or schedule wallpapers, let Kinora manage it. Your screen blinks once while macOS switches over.")
                }
            }

            Section("Status") {
                plugInRow
                wallpaperRow
                lockScreenRow
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
                WallpaperChoices()
            }
            Picker("Dark Mode", selection: Binding(get: { rules.dark }, set: { id in
                Task { await wallpaper.change { $0.dark = id } }
            })) {
                Text("Same as Light").tag(UUID?.none)
                WallpaperChoices()
            }
            if rules.darkVariantIsOverridden {
                Text(rules.schedule != nil
                     ? "The time-of-day schedule is deciding the desktop, so the Dark Mode wallpaper waits."
                     : "The rotation is deciding the desktop, so the Dark Mode wallpaper waits until it stops.")
                    .font(.caption).foregroundStyle(.secondary)
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

    /// Each connected display's own wallpaper and Lock Screen, or the main rules, and the
    /// choices kept for displays that aren't connected now.
    private var displaysSection: some View {
        Section {
            ForEach(wallpaper.displays) { display in
                let choice = wallpaper.choice(forDisplay: display.key)
                Picker(display.name, selection: Binding(get: { choice?.wallpaper }, set: { id in
                    Task {
                        if let id { await wallpaper.use(itemID: id, on: display) } else { await wallpaper.clearChoice(forDisplay: display.key) }
                    }
                })) {
                    Text("Same as Other Displays").tag(UUID?.none)
                    WallpaperChoices()
                }
                if let choice {
                    Picker("Lock Screen", selection: Binding(get: { choice.lockScreen }, set: { id in
                        Task { await wallpaper.setLockScreen(id, on: display.key) }
                    })) {
                        Text("Same as Other Displays").tag(UUID?.none)
                        WallpaperChoices()
                    }
                    .padding(.leading, 14)
                    .accessibilityLabel("\(display.name) Lock Screen")
                }
            }
            ForEach(wallpaper.disconnectedChoices) { entry in
                LabeledContent {
                    HStack {
                        Text(name(of: entry.choice.wallpaper)).foregroundStyle(.secondary)
                        Button("Forget") { Task { await wallpaper.clearChoice(forDisplay: entry.key) } }
                            .accessibilityLabel("Forget the wallpaper for \(entry.choice.name ?? "this display")")
                    }
                } label: {
                    Text(entry.choice.name ?? "Disconnected display")
                    Text("Not connected")
                }
            }
        } header: {
            Text("Displays")
        } footer: {
            Text("A display with a wallpaper of its own keeps it while the others rotate, follow the schedule or change with Dark Mode. Changes apply at once.")
        }
        .disabled(wallpaper.working)
    }

    /// Where the shown item appears: the Lock Screen too, unless it has a wallpaper of its own,
    /// and only some displays when others have their own.
    private func placement(of id: UUID) -> String {
        let dark = colorScheme == .dark
        let lock = wallpaper.shown(.locked, dark: dark)?.shown
        let surfaces = lock == id ? "desktop and Lock Screen" : "desktop"
        if let showing = wallpaper.displaysShowing(id, dark: dark), !showing.isEmpty {
            return "On the \(surfaces) of \(ListFormatter.localizedString(byJoining: showing.map(\.name)))"
        }
        return "On your \(surfaces)"
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
            } else if wallpaper.shown(dark: colorScheme == .dark)?.dependsOnUnlocks == true {
                Text("Changes each time you unlock").foregroundStyle(.secondary)
            } else if wallpaper.replacedByOther {
                Text("Another wallpaper").foregroundStyle(.secondary)
            } else {
                Text("Not Kinora").foregroundStyle(.secondary)
            }
        }
    }

    /// The Lock Screen's wallpaper, when it has one of its own.
    @ViewBuilder private var lockScreenRow: some View {
        if let lock = wallpaper.shown(.locked, dark: colorScheme == .dark),
           let lockID = lock.shown, !lock.dependsOnUnlocks,
           lockID != wallpaper.shownItem(dark: colorScheme == .dark) {
            LabeledContent("Lock Screen", value: name(of: lockID))
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

/// Every wallpaper as picker rows tagged with an optional identifier: the library, then the originals.
struct WallpaperChoices: View {
    @Environment(LibraryModel.self) private var library
    var optional = true

    var body: some View {
        Divider()
        ForEach(library.items) { item in
            if optional { Text(item.name).tag(UUID?.some(item.id)) } else { Text(item.name).tag(item.id) }
        }
        if OriginalRenderer.shared != nil {
            Divider()
            ForEach(KinoraOriginals.all) { original in
                if optional { Text(original.name).tag(UUID?.some(original.id)) } else { Text(original.name).tag(original.id) }
            }
        }
    }
}

/// Makes a Living Photo again, with other motion or for a display of another size, from the
/// copy of its photo Kinora keeps.
struct LivingPhotoRemakeSection: View {
    @Environment(LibraryModel.self) private var library
    let item: LibraryItem
    @State private var maker = LivingPhotoMaker()
    @State private var motion: LivingPhotoMotion = .subtle

    var body: some View {
        if let source = item.livingPhoto {
            let display = VideoOptimizer.largestDisplayPixels()
            let size = LivingPhotoSource.loopSize(for: display)
            let needsRemaking = source.needsRemaking(for: display)
            Section {
                Picker("Motion", selection: $motion) {
                    ForEach(LivingPhotoMotion.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                switch maker.phase {
                case .generating(let done):
                    HStack {
                        ProgressView(value: done).accessibilityLabel("Making the Living Photo again")
                        Button("Stop") { maker.cancel() }
                    }
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                    remakeButton(display: display, enabled: true)
                default:
                    remakeButton(display: display, enabled: needsRemaking || motion != source.motionStrength)
                }
            } header: {
                Text("Living Photo")
            } footer: {
                if needsRemaking {
                    Text("Made at \(source.width)×\(source.height). Your largest display needs \(Int(size.width))×\(Int(size.height)); make it again to fit.")
                } else {
                    Text("Made at \(source.width)×\(source.height) from a smaller copy of your photo, which Kinora keeps with it. Your photo itself is never changed.")
                }
            }
            .onAppear { motion = source.motionStrength }
        } else {
            Section("Living Photo") {
                Text("Made before Kinora kept a copy of the photo. To change its motion or size, make it again from the photo in Living Photos.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func remakeButton(display: CGSize, enabled: Bool) -> some View {
        Button("Make Again") { maker.remake(item, into: library, display: display, motion: motion) }
            .disabled(!enabled)
            .help("Make this Living Photo again with this motion, at your display's size")
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
