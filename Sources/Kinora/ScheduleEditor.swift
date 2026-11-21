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
                                WallpaperChoices(optional: false)
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
                    if duplicates.isEmpty {
                        Text("The schedule decides the desktop over a rotation or Dark Mode. Your Lock Screen choice is not affected.")
                    } else {
                        Label("Two changes start at \(duplicates.map(Self.timeText).formatted()). Move or remove one to save.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    HStack {
                        Button("Add Change", systemImage: "plus") { addRow() }
                            .disabled(library.items.isEmpty)
                        Button("Day and Night") { dayAndNight() }
                            .disabled(library.items.count < 2)
                            .help("One wallpaper from 7:00 and another from 19:00")
                        if rows.isEmpty, let previous = restorable {
                            Button("Restore Previous") { rows = previous.map { Row(minute: $0.startMinute, item: $0.item) } }
                                .help("Bring back the schedule you had before")
                        }
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
                    .disabled(!duplicates.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 440)
        .onAppear(perform: load)
    }

    private func load() {
        let entries = wallpaper.liveRules?.schedule ?? []
        rows = entries.map { Row(minute: $0.startMinute, item: $0.item) }.filter { library.item($0.item) != nil }
    }

    /// A schedule Kinora replaced, still made of wallpapers in the library.
    private var restorable: [WallpaperRules.ScheduleEntry]? {
        let kept = wallpaper.restorableSchedule?.filter { library.item($0.item) != nil } ?? []
        return kept.isEmpty ? nil : kept
    }

    /// Start times two rows share. Saving would keep only one of them, so it waits until they differ.
    private var duplicates: [Int] { ScheduleEditing.duplicateStarts(entries) }

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
        let day = wallpaper.liveRules?.wallpaper ?? library.items[0].id
        let night = wallpaper.liveRules?.dark ?? library.items.first { $0.id != day }?.id ?? library.items[1].id
        rows = ScheduleEditing.dayAndNight(day: day, night: night).map { Row(minute: $0.startMinute, item: $0.item) }
    }

    private func save() {
        guard duplicates.isEmpty else { return }
        Task { await wallpaper.setSchedule(entries, fallback: fallback) }
        dismiss()
    }

    /// The row's minutes after midnight, as a time today for the picker.
    private func time(for row: Binding<Row>) -> Binding<Date> {
        Binding(get: {
            Self.date(atMinute: row.wrappedValue.minute)
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            row.wrappedValue.minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }

    /// Today at a wall-clock time. Built from the hour and minute, not by adding seconds to
    /// midnight, which is an hour off on days the clocks change.
    static func date(atMinute minute: Int, calendar: Calendar = .current, on day: Date = Date()) -> Date {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
            ?? calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(minute * 60))
    }

    /// "07:00", in the user's clock style.
    static func timeText(_ minute: Int) -> String {
        date(atMinute: minute).formatted(date: .omitted, time: .shortened)
    }
}
