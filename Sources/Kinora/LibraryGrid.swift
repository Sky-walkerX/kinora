// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import SwiftUI

/// The user's wallpapers.
struct LibraryPage: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @Binding var selection: UUID?
    @Binding var choosingFiles: Bool

    var body: some View {
        Group {
            if library.items.isEmpty {
                ContentUnavailableView {
                    Label("Drop a video here", systemImage: "play.rectangle.on.rectangle")
                } description: {
                    Text("Kinora plays it on your desktop and Lock Screen, and pauses it when you can't see it.")
                } actions: {
                    Button("Choose Videos…") { choosingFiles = true }
                }
            } else {
                LibraryGrid(items: library.items, selection: $selection)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Rotate", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                    Section("Rotate through all wallpapers") {
                        ForEach(RotationChoice.allCases) { choice in
                            Button(choice.title) { Task { await rotateAll(every: choice.interval) } }
                        }
                    }
                }
                .disabled(library.items.count < 2 || wallpaper.working)
                .help("Change wallpapers automatically")
            }
        }
    }

    private func rotateAll(every interval: TimeInterval) async {
        let items: [UUID] = library.items.map(\.id)
        guard let first = items.first else { return }
        var rules = wallpaper.editableRules(fallback: first)
        rules.schedule = nil
        rules.rotation = WallpaperRules.Rotation(items: items, interval: interval, since: Date())
        await wallpaper.apply(rules)
    }
}

/// A grid of library items with selection, "Use as Wallpaper", playlists, rename and removal.
struct LibraryGrid: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    let items: [LibraryItem]
    @Binding var selection: UUID?
    /// Set inside a playlist, which offers "Remove from Playlist" as well.
    var playlistID: UUID?
    @State private var renaming: LibraryItem?
    @State private var newName = ""
    @State private var removing: LibraryItem?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 18)], spacing: 22) {
                ForEach(items) { item in
                    tile(item)
                }
            }
            .padding(22)
        }
        .alert("Rename Wallpaper", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { library.rename(renaming, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .removalConfirmation(for: $removing)
    }

    private func tile(_ item: LibraryItem) -> some View {
        LibraryTile(item: item, thumbnail: library.thumbnailURL(item), isSelected: selection == item.id,
                    isCurrent: wallpaper.currentItem == item.id)
            .onTapGesture { selection = item.id }
            .simultaneousGesture(TapGesture(count: 2).onEnded { Task { await wallpaper.use(item) } })
            .contextMenu {
                Button("Use as Wallpaper") { Task { await wallpaper.use(item) } }
                Menu("Add to Playlist") {
                    ForEach(library.playlists) { playlist in
                        Button(playlist.name) { addToPlaylist(item.id, playlist.id) }
                            .disabled(playlist.items.contains(item.id))
                    }
                    if !library.playlists.isEmpty { Divider() }
                    Button("New Playlist") { library.createPlaylist(named: "New Playlist", items: [item.id]) }
                }
                Button("Rename…") { newName = item.name; renaming = item }
                Divider()
                if let playlistID {
                    Button("Remove from Playlist") { removeFromPlaylist(item.id, playlistID) }
                }
                Button("Remove from Library…", role: .destructive) { removing = item }
            }
    }

    private func addToPlaylist(_ itemID: UUID, _ playlistID: UUID) {
        library.add(itemID, toPlaylist: playlistID)
        if let playlist = library.playlist(playlistID) { Task { await wallpaper.playlistChanged(playlist) } }
    }

    private func removeFromPlaylist(_ itemID: UUID, _ playlistID: UUID) {
        guard let playlist = library.playlist(playlistID) else { return }
        library.setPlaylistItems(playlistID, playlist.items.filter { $0 != itemID })
        if let updated = library.playlist(playlistID) { Task { await wallpaper.playlistChanged(updated) } }
    }
}

extension View {
    /// Asks before removing an item, says where Kinora uses it, and takes it out of the
    /// wallpaper rules first so the desktop never points at something that is gone.
    func removalConfirmation(for item: Binding<LibraryItem?>) -> some View {
        modifier(RemovalConfirmation(item: item))
    }
}

private struct RemovalConfirmation: ViewModifier {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @Binding var item: LibraryItem?

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
                                   titleVisibility: .visible, presenting: item) { item in
            Button("Remove", role: .destructive) { Task { await remove(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(message(for: item))
        }
    }

    private var title: String {
        guard let item else { return "Remove Wallpaper?" }
        return "Remove “\(item.name)”?"
    }

    private func message(for item: LibraryItem) -> String {
        let uses = wallpaper.uses(of: item.id)
        var parts: [String] = []
        if !uses.isEmpty {
            let list = ListFormatter.localizedString(byJoining: uses.map(\.description))
            parts.append("It's used for \(list). Kinora will use another wallpaper there instead.")
        }
        if item.kind == .appleAerial {
            parts.append("The aerial stays on your Mac; only Kinora's entry is removed.")
        } else {
            parts.append("Kinora deletes its copy. The file you imported is not touched.")
        }
        return parts.joined(separator: " ")
    }

    private func remove(_ item: LibraryItem) async {
        let replacement = library.items.first { $0.id != item.id }?.id
        guard await wallpaper.forget(item.id, replacement: replacement) else {
            wallpaper.lastError = "“\(item.name)” is the only wallpaper Kinora is showing. Add another one first, or use Restore Original Wallpaper."
            return
        }
        library.remove(item)
    }
}

struct LibraryTile: View {
    let item: LibraryItem
    let thumbnail: URL
    let isSelected: Bool
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(url: thumbnail)
                .clipShape(.rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 3 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .padding(7)
                            .accessibilityLabel("Current wallpaper")
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let badge = KindBadge(kind: item.kind) {
                        badge.padding(7)
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            Text(item.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small mark on tiles that are not plain videos.
struct KindBadge: View {
    let symbol: String
    let label: String

    init?(kind: LibraryItem.Kind) {
        guard let mark = Self.mark(for: kind) else { return nil }
        symbol = mark.symbol
        label = mark.label
    }

    private static func mark(for kind: LibraryItem.Kind) -> (symbol: String, label: String)? {
        if kind == .livingPhoto { return ("person.and.background.dotted", "Living Photo") }
        if kind == .appleAerial { return ("airplane", "Apple Aerial") }
        if kind == .package { return ("shippingbox", "Installed package") }
        return nil
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.45), in: .circle)
            .accessibilityLabel(label)
            .help(label)
    }
}

/// A wallpaper's still in a fixed 16:10 frame, filled and cropped, so every tile lines up
/// whatever the video's shape.
struct Thumbnail: View {
    let url: URL

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .clipped()
    }
}

/// How often a rotation changes wallpaper.
enum RotationChoice: CaseIterable, Identifiable {
    case quarterHour, hour, fourHours, day, unlock

    var id: Self { self }

    var interval: TimeInterval {
        switch self {
        case .quarterHour: 15 * 60
        case .hour: 3600
        case .fourHours: 4 * 3600
        case .day: 24 * 3600
        case .unlock: 0
        }
    }

    var title: String {
        switch self {
        case .quarterHour: "Every 15 Minutes"
        case .hour: "Every Hour"
        case .fourHours: "Every 4 Hours"
        case .day: "Every Day"
        case .unlock: "Each Time You Unlock"
        }
    }

    static func describe(_ interval: TimeInterval) -> String {
        allCases.first { $0.interval == interval }.map { $0.title.lowercased() }
            ?? Duration.seconds(interval).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}
