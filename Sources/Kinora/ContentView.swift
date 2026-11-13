// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's sections.
enum SidebarItem: Hashable {
    case library
    case livingPhotos
    case originals
    case aerials
    case playlist(UUID)
}

struct ContentView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @State private var section: SidebarItem? = .library
    @State private var selection: UUID?
    @State private var showInspector = true
    @State private var choosingFiles = false
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            Sidebar(section: $section)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(.tint, lineWidth: 3).padding(8).allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    Task { await library.importVideos(urls) }
                    return !urls.isEmpty
                } isTargeted: { dropTargeted = $0 }
                .inspector(isPresented: $showInspector) {
                    Inspector(itemID: selection)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add Videos", systemImage: "plus") { choosingFiles = true }
                            .help("Add videos or folders of videos to your library")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
                    }
                }
        }
        .navigationTitle("Kinora")
        .navigationSubtitle(subtitle)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.movie, .folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                await library.importVideos(urls)
                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            }
        }
        .alert("Something went wrong", isPresented: errorShown, presenting: library.lastError ?? wallpaper.lastError) { _ in
            Button("OK") { library.lastError = nil; wallpaper.lastError = nil }
        } message: { Text($0) }
        .onChange(of: library.items) { _, items in
            let ids: [UUID] = items.map(\.id)
            if let selection, ids.contains(selection) || KinoraOriginals.isOriginal(selection) { return }
            selection = Self.preferred(current: wallpaper.currentItem, among: ids)
        }
        .onAppear { selection = Self.preferred(current: wallpaper.currentItem, among: library.items.map(\.id)) }
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .library {
        case .library:
            LibraryPage(selection: $selection, choosingFiles: $choosingFiles)
        case .livingPhotos:
            LivingPhotosPage(selection: $selection)
        case .originals:
            OriginalsPage(selection: $selection)
        case .aerials:
            AerialsPage(selection: $selection)
        case .playlist(let id):
            PlaylistPage(playlistID: id, selection: $selection, section: $section)
        }
    }

    /// The current wallpaper when it is in the library, else the first item. Kept as plain
    /// statements: Swift 6.3's type checker times out on the one-expression version.
    private static func preferred(current: UUID?, among ids: [UUID]) -> UUID? {
        if let current, ids.contains(current) { return current }
        return ids.first
    }

    private var subtitle: String {
        if library.importing > 0 { return "Importing…" }
        let count = library.items.count == 1 ? "1 wallpaper" : "\(library.items.count) wallpapers"
        let saved = library.savedBytes
        return saved > 0 ? "\(count) · \(saved.formatted(.byteCount(style: .file))) saved" : count
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { library.lastError != nil || wallpaper.lastError != nil },
                set: { if !$0 { library.lastError = nil; wallpaper.lastError = nil } })
    }
}

/// Library sections, playlists and the gallery.
struct Sidebar: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @Binding var section: SidebarItem?
    @State private var renaming: Playlist?
    @State private var newName = ""

    var body: some View {
        List(selection: $section) {
            Section("Library") {
                Label("Your Wallpapers", systemImage: "photo.on.rectangle").tag(SidebarItem.library)
                Label("Living Photos", systemImage: "person.and.background.dotted").tag(SidebarItem.livingPhotos)
                Label("Kinora Originals", systemImage: "sparkles").tag(SidebarItem.originals)
                Label("Apple Aerials", systemImage: "airplane").tag(SidebarItem.aerials)
            }
            Section("Playlists") {
                ForEach(library.playlists) { playlist in
                    PlaylistRow(playlist: playlist, isPlaying: wallpaper.selection?.rules.rotation?.playlist == playlist.id)
                        .tag(SidebarItem.playlist(playlist.id))
                        .contextMenu {
                            Button("Rename…") { newName = playlist.name; renaming = playlist }
                            Button("Delete Playlist", role: .destructive) { delete(playlist) }
                        }
                }
                Button {
                    let playlist = library.createPlaylist(named: "New Playlist")
                    section = .playlist(playlist.id)
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { library.renamePlaylist(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func delete(_ playlist: Playlist) {
        if section == .playlist(playlist.id) { section = .library }
        library.deletePlaylist(playlist.id)
        var emptied = playlist
        emptied.items = []
        Task { await wallpaper.playlistChanged(emptied) }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let isPlaying: Bool

    var body: some View {
        Label {
            Text(playlist.name)
        } icon: {
            Image(systemName: isPlaying ? "play.circle.fill" : "music.note.list")
        }
        .badge(playlist.items.count)
        .accessibilityValue(isPlaying ? "Playing" : "")
    }
}
