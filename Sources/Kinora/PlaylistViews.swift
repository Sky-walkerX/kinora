// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import SwiftUI

/// One playlist: its wallpapers, and playing it on the desktop.
struct PlaylistPage: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    let playlistID: UUID
    @Binding var selection: UUID?
    @Binding var section: SidebarItem?
    @State private var editing = false
    @State private var shuffle = false

    var body: some View {
        if let playlist = library.playlist(playlistID) {
            content(playlist)
                .navigationSubtitle(playlist.name)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Play", systemImage: "play.fill") {
                            Toggle("Shuffle", isOn: $shuffle)
                            Divider()
                            ForEach(RotationChoice.allCases) { choice in
                                Button("Change \(choice.title)") {
                                    Task { await wallpaper.play(playlist, every: choice.interval, shuffle: shuffle) }
                                }
                            }
                        }
                        .disabled(playlist.items.isEmpty || wallpaper.working)
                        .help("Rotate through this playlist on your desktop")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit Playlist", systemImage: "checklist") { editing = true }
                            .help("Choose the wallpapers in this playlist")
                    }
                }
                .sheet(isPresented: $editing) {
                    PlaylistEditor(playlist: playlist)
                }
        } else {
            ContentUnavailableView("No Playlist", systemImage: "music.note.list")
        }
    }

    @ViewBuilder private func content(_ playlist: Playlist) -> some View {
        let items: [LibraryItem] = playlist.items.compactMap { library.item($0) }
        if items.isEmpty {
            ContentUnavailableView {
                Label("An Empty Playlist", systemImage: "music.note.list")
            } description: {
                Text("Add wallpapers, then play the playlist to change your desktop on a timer or each time you unlock.")
            } actions: {
                Button("Add Wallpapers…") { editing = true }
                    .disabled(library.items.isEmpty)
            }
        } else {
            LibraryGrid(items: items, selection: $selection, playlistID: playlist.id)
        }
    }
}

/// Picks and orders a playlist's wallpapers.
struct PlaylistEditor: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    @State private var chosen: [UUID] = []
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name)
                Section {
                    List {
                        ForEach(library.items) { item in
                            Toggle(isOn: binding(for: item.id)) {
                                HStack(spacing: 10) {
                                    Thumbnail(url: library.thumbnailURL(item))
                                        .frame(width: 64)
                                        .clipShape(.rect(cornerRadius: 4))
                                    Text(item.name).lineLimit(1)
                                    Spacer()
                                    if let position = chosen.firstIndex(of: item.id) {
                                        Text("\(position + 1)").foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(minHeight: 260)
                } header: {
                    Text("Wallpapers")
                } footer: {
                    Text("The playlist plays in the order you tick them, unless you shuffle it.")
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
        .frame(width: 440, height: 520)
        .onAppear {
            chosen = playlist.items
            name = playlist.name
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { chosen.contains(id) }, set: { isOn in
            if isOn { if !chosen.contains(id) { chosen.append(id) } } else { chosen.removeAll { $0 == id } }
        })
    }

    private func save() {
        library.renamePlaylist(playlist.id, to: name)
        library.setPlaylistItems(playlist.id, chosen)
        if let updated = library.playlist(playlist.id) { Task { await wallpaper.playlistChanged(updated) } }
        dismiss()
    }
}
