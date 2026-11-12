// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @State private var selection: LibraryItem.ID?
    @State private var choosingFiles = false
    @State private var showInspector = true
    @State private var dropTargeted = false

    private var selectedItem: LibraryItem? { library.items.first { $0.id == selection } }

    var body: some View {
        Group {
            if library.items.isEmpty {
                emptyState
            } else {
                LibraryGrid(selection: $selection)
            }
        }
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
            Inspector(item: selectedItem)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Videos", systemImage: "plus") { choosingFiles = true }
                    .help("Add videos to your library")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
            }
        }
        .navigationTitle("Kinora")
        .navigationSubtitle(library.importing > 0 ? "Importing…" : "\(library.items.count) wallpapers")
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
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
            if selection == nil || !items.contains(where: { $0.id == selection }) {
                selection = wallpaper.currentItem.flatMap { id in items.first { $0.id == id }?.id } ?? items.first?.id
            }
        }
        .onAppear { selection = wallpaper.currentItem ?? library.items.first?.id }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { library.lastError != nil || wallpaper.lastError != nil },
                set: { if !$0 { library.lastError = nil; wallpaper.lastError = nil } })
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Drop a video here", systemImage: "play.rectangle.on.rectangle")
        } description: {
            Text("Kinora plays it on your desktop and Lock Screen, and pauses it when you can't see it.")
        } actions: {
            Button("Choose Videos…") { choosingFiles = true }
        }
    }
}

struct LibraryGrid: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @Binding var selection: LibraryItem.ID?
    @State private var renaming: LibraryItem?
    @State private var newName = ""

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 18)], spacing: 22) {
                ForEach(library.items) { item in
                    LibraryTile(item: item, thumbnail: library.thumbnailURL(item), isSelected: selection == item.id,
                                isCurrent: wallpaper.currentItem == item.id)
                        .onTapGesture { selection = item.id }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { Task { await wallpaper.use(item) } })
                        .contextMenu {
                            Button("Use as Wallpaper") { Task { await wallpaper.use(item) } }
                            Button("Rename…") { newName = item.name; renaming = item }
                            Divider()
                            Button("Remove from Library", role: .destructive) { library.remove(item) }
                                .disabled(wallpaper.currentItem == item.id)
                        }
                }
            }
            .padding(22)
        }
        .alert("Rename Wallpaper", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { library.rename(renaming, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
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
                .aspectRatio(16 / 10, contentMode: .fit)
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

struct Thumbnail: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary).overlay { Image(systemName: "film").foregroundStyle(.secondary) }
        }
    }
}
