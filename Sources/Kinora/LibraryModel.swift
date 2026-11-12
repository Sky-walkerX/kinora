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
    private(set) var importing = 0
    var lastError: String?

    let location: LibraryLocation

    init(location: LibraryLocation = .current) {
        self.location = location
        load()
    }

    func thumbnailURL(_ item: LibraryItem) -> URL { location.thumbnailURL(for: item) }

    /// Copies playable videos into the library. Files that are not playable video are reported, not imported.
    func importVideos(_ urls: [URL]) async {
        importing += urls.count
        defer { importing -= urls.count }
        var rejected: [String] = []
        for url in urls {
            do {
                items.append(try await Self.makeItem(from: url, in: location))
            } catch {
                rejected.append(url.lastPathComponent)
            }
        }
        save()
        if !rejected.isEmpty {
            lastError = "Kinora can't play \(rejected.joined(separator: ", ")). Try an MP4 or MOV video."
        }
    }

    func remove(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: location.mediaURL(for: item))
        try? FileManager.default.removeItem(at: location.thumbnailURL(for: item))
        save()
    }

    func rename(_ item: LibraryItem, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].name = trimmed
        save()
    }

    // MARK: - Storage

    private func load() {
        guard let data = try? Data(contentsOf: location.index), let index = LibraryIndex.decode(data) else { return }
        items = index.items
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
            try LibraryIndex(items: items).encoded().write(to: location.index, options: .atomic)
            // The plug-in reloads and refreshes System Settings' tiles.
            notify_post(KinoraIdentity.libraryChangedNotification)
        } catch {
            lastError = "Kinora couldn't save its library: \(error.localizedDescription)"
        }
    }

    private static func makeItem(from source: URL, in location: LibraryLocation) async throws -> LibraryItem {
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isPlayable), try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let id = UUID()
        let fm = FileManager.default
        try fm.createDirectory(at: location.mediaFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: location.thumbnailFolder, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let item = LibraryItem(id: id, name: source.deletingPathExtension().lastPathComponent, kind: .video,
                               media: "\(id.uuidString).\(ext)", thumbnail: "\(id.uuidString).png", addedAt: Date())
        try fm.copyItem(at: source, to: location.mediaURL(for: item))
        do {
            try await writeThumbnail(of: AVURLAsset(url: location.mediaURL(for: item)), to: location.thumbnailURL(for: item))
        } catch {
            try? fm.removeItem(at: location.mediaURL(for: item))
            throw error
        }
        return item
    }

    /// A still from one second in (or the start of a shorter video), at most 1280 points wide.
    private static func writeThumbnail(of asset: AVURLAsset, to url: URL) async throws {
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
