// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import SwiftUI

/// Edits the desktop's time-of-day schedule: at each listed time, the desktop changes to the
/// chosen wallpaper and stays until the next time.
struct ScheduleEditor: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @Environment(\.dismiss) private var dismiss
    /// Used when there are no rules yet.
    let fallback: UUID
    @State private var rows: [Row] = []

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var minute: Int
        var item: UUID
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if rows.isEmpty {
                        Text("No changes. Your desktop shows the same wallpaper all day.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($rows) { $row in
                        HStack {
                            DatePicker("From", selection: time(for: $row), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Picker("Wallpaper", selection: $row.item) {
                                ForEach(library.items) { item in
                                    Text(item.name).tag(item.id)
                                }
                            }
                            .labelsHidden()
                            Button("Remove", systemImage: "minus.circle") { rows.removeAll { $0.id == row.id } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Remove this change")
                        }
                    }
                } header: {
                    Text("Time of Day")
                } footer: {
                    Text("The schedule decides the desktop over a rotation or Dark Mode. Your Lock Screen choice is not affected.")
                }
                Section {
                    HStack {
                        Button("Add Change", systemImage: "plus") { addRow() }
                            .disabled(library.items.isEmpty)
                        Button("Day and Night") { dayAndNight() }
                            .disabled(library.items.count < 2)
                            .help("One wallpaper from 7:00 and another from 19:00")
                        Spacer()
                        Button("Turn Off", role: .destructive) { rows.removeAll() }
                            .disabled(rows.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 440)
        .onAppear(perform: load)
    }

    private func load() {
        let entries = wallpaper.selection?.rules.schedule ?? []
        rows = entries.map { Row(minute: $0.startMinute, item: $0.item) }.filter { library.item($0.item) != nil }
    }

    private var entries: [WallpaperRules.ScheduleEntry] {
        rows.map { WallpaperRules.ScheduleEntry(startMinute: $0.minute, item: $0.item) }
    }

    private func addRow() {
        let item = library.items.first { candidate in !rows.contains { $0.item == candidate.id } }?.id ?? library.items.first?.id
        guard let item else { return }
        rows.append(Row(minute: ScheduleEditing.suggestedStart(after: entries), item: item))
        rows.sort { $0.minute < $1.minute }
    }

    private func dayAndNight() {
        guard library.items.count >= 2 else { return }
        let day = wallpaper.selection?.rules.wallpaper ?? library.items[0].id
        let night = wallpaper.selection?.rules.dark ?? library.items.first { $0.id != day }?.id ?? library.items[1].id
        rows = ScheduleEditing.dayAndNight(day: day, night: night).map { Row(minute: $0.startMinute, item: $0.item) }
    }

    private func save() {
        Task { await wallpaper.setSchedule(entries, fallback: fallback) }
        dismiss()
    }

    /// The row's minutes after midnight, as a time today for the picker.
    private func time(for row: Binding<Row>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(row.wrappedValue.minute * 60))
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            row.wrappedValue.minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
}

extension WallpaperRules.ScheduleEntry {
    /// "07:00", in the user's clock style.
    var timeText: String {
        let date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(startMinute * 60))
        return date.formatted(date: .omitted, time: .shortened)
    }
}
