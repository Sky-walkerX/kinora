// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import Foundation
import ImageIO
import KinoraKit
import notify
import Observation
import UniformTypeIdentifiers

/// The user's library: imported videos, their thumbnails, and the index the plug-in reads.
@MainActor @Observable final class LibraryModel {
    private(set) var items: [LibraryItem] = []
    private(set) var playlists: [Playlist] = []
    private(set) var importing = 0
    var lastError: String?

    let location: LibraryLocation

    init(location: LibraryLocation = .current) {
        self.location = location
        load()
        clearWork()
    }

    func thumbnailURL(_ item: LibraryItem) -> URL { location.thumbnailURL(for: item) }
    /// A library item, or one of Kinora's originals as an item.
    func item(_ id: UUID) -> LibraryItem? { items.first { $0.id == id } ?? KinoraOriginals.original(id)?.libraryItem }
    func playlist(_ id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    /// Copies playable videos into the library; folders are searched for videos. Files that are
    /// not playable video are reported, not imported.
    func importVideos(_ urls: [URL]) async {
        let files = Self.expandingFolders(urls)
        importing += files.count
        defer { importing -= files.count }
        var rejected: [String] = []
        let display = VideoOptimizer.largestDisplayPixels()
        for url in files {
            do {
                items.append(try await Self.makeItem(from: url, in: location, display: display))
                save()
            } catch {
                rejected.append(url.lastPathComponent)
            }
        }
        if files.isEmpty, !urls.isEmpty {
            lastError = "There are no videos in \(urls.map(\.lastPathComponent).joined(separator: ", "))."
        } else if !rejected.isEmpty {
            lastError = Self.unsupportedMessage(rejected)
        }
    }

    /// Adds an item made elsewhere, such as a Living Photo, whose files are already in the library.
    func add(_ item: LibraryItem) {
        items.append(item)
        save()
    }

    /// Removes an item and the files Kinora made for it. Media Kinora only points at, such as
    /// Apple's aerials, is left alone.
    func remove(_ item: LibraryItem) {
        let index = LibraryIndex(items: items, playlists: playlists).removing(item.id)
        items = index.items
        playlists = index.playlists ?? []
        if let owned = location.ownedMediaURL(for: item) { try? FileManager.default.removeItem(at: owned) }
        try? FileManager.default.removeItem(at: location.thumbnailURL(for: item))
        save()
    }

    // MARK: - Apple's aerials

    /// The aerials macOS has downloaded, read fresh each time.
    nonisolated static func downloadedAerials() -> [AppleAerials.Aerial] {
        let fm = FileManager.default
        var found: [AppleAerials.Aerial] = []
        for place in AppleAerials.locations(home: realHomeDirectory()) {
            guard let catalog = try? Data(contentsOf: place.catalog),
                  let names = try? fm.contentsOfDirectory(atPath: place.videos.path) else { continue }
            for aerial in AppleAerials.downloaded(catalog: catalog, downloaded: Set(names)) where !found.contains(where: { $0.id == aerial.id }) {
                found.append(aerial)
            }
        }
        return found
    }

    func contains(_ aerial: AppleAerials.Aerial) -> Bool {
        items.contains { $0.kind == .appleAerial && $0.media == aerial.fileName }
    }

    /// Adds an aerial to the library. Kinora plays it where macOS keeps it; only a thumbnail is made.
    func addAerial(_ aerial: AppleAerials.Aerial) async {
        guard !contains(aerial) else { return }
        importing += 1
        defer { importing -= 1 }
        let id = UUID()
        var item = LibraryItem(id: id, name: aerial.name, kind: .appleAerial, media: aerial.fileName,
                               thumbnail: "\(id.uuidString).png", addedAt: Date())
        item.attribution = LibraryItem.Attribution(author: "Apple", license: "Included with macOS; not redistributed by Kinora")
        do {
            try FileManager.default.createDirectory(at: location.thumbnailFolder, withIntermediateDirectories: true)
            try await Self.writeThumbnail(of: AVURLAsset(url: location.mediaURL(for: item)), to: location.thumbnailURL(for: item))
            items.append(item)
            save()
        } catch {
            lastError = "Kinora couldn't open the aerial “\(aerial.name)”. Download it again in System Settings › Wallpaper."
        }
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(named name: String, items ids: [UUID] = []) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmed.isEmpty ? "Playlist" : trimmed, items: ids.filter { item($0) != nil })
        playlists.append(playlist)
        save()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = trimmed
        save()
    }

    func setPlaylistItems(_ id: UUID, _ ids: [UUID]) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var seen: Set<UUID> = []
        playlists[index].items = ids.filter { item($0) != nil && seen.insert($0).inserted }
        save()
    }

    func add(_ itemID: UUID, toPlaylist id: UUID) {
        guard let playlist = playlist(id), !playlist.items.contains(itemID) else { return }
        setPlaylistItems(id, playlist.items + [itemID])
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func rename(_ item: LibraryItem, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].name = trimmed
        save()
    }

    /// Tells the plug-in to reload the library, settings and selection, and to refresh System
    /// Settings' tiles.
    static func postLibraryChanged() {
        notify_post(KinoraIdentity.libraryChangedNotification)
    }

    // MARK: - Storage

    private func load() {
        guard let data = try? Data(contentsOf: location.index), let index = LibraryIndex.decode(data) else { return }
        items = index.items
        playlists = index.playlists ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
            try LibraryIndex(items: items, playlists: playlists).encoded().write(to: location.index, options: .atomic)
            Self.postLibraryChanged()
        } catch {
            lastError = "Kinora couldn't save its library: \(error.localizedDescription)"
        }
    }

    /// Removes work a previous run left unfinished, such as a Living Photo cancelled by quitting.
    private func clearWork() {
        try? FileManager.default.removeItem(at: location.workFolder)
    }

    /// A fresh folder for one piece of work, inside the library so moving its result is cheap.
    func makeWorkFolder() throws -> URL {
        let folder = location.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Video files in `urls`, looking two folders deep into any folder.
    nonisolated static func expandingFolders(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            guard isFolder.boolValue else { files.append(url); continue }
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
            guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in walker {
                if walker.level > 3 { walker.skipDescendants(); continue }
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      values.contentType?.conforms(to: .movie) == true else { continue }
                files.append(file)
            }
        }
        return files
    }

    /// Says why files were not imported, naming formats Kinora knows it cannot play.
    nonisolated static func unsupportedMessage(_ names: [String]) -> String {
        let list = names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " and \(names.count - 4) more" : "")
        let webm = names.contains { ["webm", "mkv"].contains(($0 as NSString).pathExtension.lowercased()) }
        if webm {
            return "Kinora can't play \(list). WebM and MKV videos aren't supported yet: macOS can't open them directly. Convert them to MP4 or MOV first."
        }
        return "Kinora can't play \(list). Try an MP4 or MOV video."
    }

    private static func makeItem(from source: URL, in location: LibraryLocation, display: CGSize) async throws -> LibraryItem {
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isPlayable), try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let id = UUID()
        let fm = FileManager.default
        try fm.createDirectory(at: location.mediaFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: location.thumbnailFolder, withIntermediateDirectories: true)
        let originalBytes = Self.fileSize(source)
        // Convert once for the displays it will play on; keep the original only when that is smaller.
        let optimized = location.mediaFolder.appendingPathComponent("\(id.uuidString).mov")
        var media = optimized.lastPathComponent
        do {
            try await VideoOptimizer.optimize(source, to: optimized, display: display)
            if !VideoOptimization.keepsOptimized(originalBytes: originalBytes, optimizedBytes: Self.fileSize(optimized)) {
                throw CancellationError()
            }
        } catch {
            try? fm.removeItem(at: optimized)
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
            media = "\(id.uuidString).\(ext)"
            try fm.copyItem(at: source, to: location.mediaFolder.appendingPathComponent(media))
        }
        var item = LibraryItem(id: id, name: source.deletingPathExtension().lastPathComponent, kind: .video,
                               media: media, thumbnail: "\(id.uuidString).png", addedAt: Date())
        item.originalBytes = originalBytes
        item.storedBytes = Self.fileSize(location.mediaURL(for: item))
        do {
            try await writeThumbnail(of: AVURLAsset(url: location.mediaURL(for: item)), to: location.thumbnailURL(for: item))
        } catch {
            try? fm.removeItem(at: location.mediaURL(for: item))
            throw error
        }
        return item
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Disk space conversion has saved across the library.
    var savedBytes: Int64 { items.reduce(0) { $0 + $1.savedBytes } }

    /// A still from one second in (or the start of a shorter video), at most 1280 points wide.
    static func writeThumbnail(of asset: AVURLAsset, to url: URL) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let duration = try await asset.load(.duration)
        let time = CMTimeMinimum(CMTime(seconds: 1, preferredTimescale: 600), CMTimeMultiplyByFloat64(duration, multiplier: 0.5))
        let image = try await generator.image(at: time).image
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
