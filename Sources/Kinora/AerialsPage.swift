// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import SwiftUI

/// Apple's aerials that macOS has already downloaded. Adding one makes a library entry that
/// plays the aerial where macOS keeps it, so it can join playlists, schedules and variants.
struct AerialsPage: View {
    @Environment(LibraryModel.self) private var library
    @Binding var selection: UUID?
    @State private var aerials: [AppleAerials.Aerial]?

    var body: some View {
        Group {
            if let aerials, aerials.isEmpty {
                ContentUnavailableView {
                    Label("No Aerials Downloaded", systemImage: "airplane")
                } description: {
                    Text("Download aerials in System Settings › Wallpaper, then come back. Kinora plays them from where macOS keeps them and never copies them.")
                } actions: {
                    Button("Open Wallpaper Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
            } else if let aerials {
                List(aerials) { aerial in
                    AerialRow(aerial: aerial, selection: $selection)
                }
                .listStyle(.inset)
            } else {
                ProgressView()
            }
        }
        .navigationSubtitle("Apple Aerials")
        .task { await reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .help("Look again for aerials macOS has downloaded")
            }
        }
    }

    private func reload() async {
        aerials = await Task.detached { LibraryModel.downloadedAerials() }.value
    }
}

private struct AerialRow: View {
    @Environment(LibraryModel.self) private var library
    let aerial: AppleAerials.Aerial
    @Binding var selection: UUID?

    var body: some View {
        HStack {
            Image(systemName: "airplane").foregroundStyle(.secondary)
            Text(aerial.name)
            Spacer()
            if let item = libraryItem {
                Button("Show in Library") { selection = item.id }
                    .buttonStyle(.borderless)
            } else {
                Button("Add to Library") { Task { await library.addAerial(aerial) } }
                    .disabled(library.importing > 0)
            }
        }
        .padding(.vertical, 2)
    }

    private var libraryItem: LibraryItem? {
        library.items.first { $0.kind == .appleAerial && $0.media == aerial.fileName }
    }
}
