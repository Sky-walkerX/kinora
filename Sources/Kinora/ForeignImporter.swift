// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import KinoraKit
import KinoraMedia

/// Imports Lively and Wallpaper Engine wallpapers the user already has, as folders or zips:
/// videos, GIFs and pictures. Everything else gets a plain explanation. No Steam, and nothing
/// from the wallpaper is ever run.
enum ForeignImporter {
    enum Failure: LocalizedError {
        case unsupported(String, ForeignWallpaper.Unsupported)
        case unreadable(String)
        case missingFile(String)

        var errorDescription: String? {
            switch self {
            case let .unsupported(name, reason): "Kinora can't import “\(name)”. \(reason.description)"
            case let .unreadable(name): "Kinora couldn't read the wallpaper settings in “\(name)”."
            case let .missingFile(name): "“\(name)” names a file that isn't in its folder."
            }
        }
    }

    /// The kind of manifest at `url`, a folder or a zip, if any. A zip's directory is read
    /// without extracting anything; it is checked properly when imported.
    static func manifest(at url: URL) -> ForeignWallpaper.Source? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue {
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            return ForeignWallpaper.manifest(in: names)?.source
        }
        guard url.pathExtension.lowercased() == "zip", let archive = try? ZipArchive(url: url, maxEntries: maxEntries) else { return nil }
        // At the top level or in the only folder, where the import looks.
        let names = Set(archive.entries.filter { !$0.isMetadata && $0.components.count <= 2 }.compactMap { $0.components.last })
        return ForeignWallpaper.manifest(in: names)?.source
    }

    /// Lively web wallpapers can hold many files; only the manifest and one media file are ever read.
    static let maxEntries = 4096

    @MainActor static func importWallpaper(at url: URL, manifest source: ForeignWallpaper.Source, library: LibraryModel,
                                           display: CGSize) async throws -> LibraryItem {
        let work = try library.makeWorkFolder()
        defer { LibraryModel.removeWork(work) }
        let manifestName = source == .lively ? ForeignWallpaper.livelyManifest : ForeignWallpaper.wallpaperEngineManifest
        let displayName = url.deletingPathExtension().lastPathComponent
        // Lively's paths may be four folders deep, inside the archive's one top folder.
        let folder = try await PackageInstaller.background {
            try PackageSource.open(url, work: work, manifests: [manifestName], maxEntries: maxEntries, maxDepth: 5)
        }
        guard let data = try? folder.read(manifestName, limit: ForeignWallpaper.manifestBytes),
              let wallpaper = ForeignWallpaper.parse(data, source: source, folderName: displayName)
        else { throw Failure.unreadable(displayName) }
        let file: String
        switch ForeignWallpaper.support(wallpaper) {
        case .success(let path): file = path
        case .failure(let reason): throw Failure.unsupported(wallpaper.title, reason)
        }
        // The file must be a plain file inside the wallpaper, after following any links.
        let isPicture: Bool
        if case .picture = wallpaper.kind { isPicture = true } else { isPicture = false }
        let limit = isPicture ? PackageLimits.imageBytes : PackageLimits.videoBytes
        let media: URL
        do {
            media = try await PackageInstaller.background { try folder.file(file, work: work, limit: limit) }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PackageSource.Failure where failure == .tooLarge {
            throw failure
        } catch {
            throw Failure.missingFile(wallpaper.title)
        }

        var item: LibraryItem
        switch wallpaper.kind {
        case .gif:
            item = try await importGIF(media, library: library, display: display, name: wallpaper.title)
        case .picture:
            let location = library.location
            item = try await PackageInstaller.background {
                try LibraryModel.makeStillItem(from: media, in: location, display: display, allowedTypes: LibraryModel.packageImageTypes)
            }
        default:
            if MatroskaConverter.isMatroska(media) {
                item = try await importMatroska(media, library: library, display: display, name: wallpaper.title)
            } else {
                item = try await LibraryModel.makeItem(from: media, in: library.location, display: display)
            }
        }
        item.name = wallpaper.title
        item.attribution = LibraryItem.Attribution(
            author: wallpaper.author,
            license: wallpaper.license ?? (source == .wallpaperEngine ? "From Wallpaper Engine; for your own use" : nil))
        return item
    }

    /// Converts a WebM or Matroska video to HEVC once, as macOS can't open those containers.
    @MainActor static func importMatroska(_ url: URL, library: LibraryModel, display: CGSize, name: String?) async throws -> LibraryItem {
        let work = try library.makeWorkFolder()
        defer { LibraryModel.removeWork(work) }
        let converted = work.appendingPathComponent("converted.mov")
        _ = try await MatroskaConverter.convert(url, to: converted, display: display)
        // Already encoded for the display, so it is not encoded twice.
        var item = try await LibraryModel.makeItem(from: converted, in: library.location, display: display, optimize: false)
        item.name = name ?? url.deletingPathExtension().lastPathComponent
        item.originalBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return item
    }

    /// Converts an animated GIF to video once; a single-frame GIF becomes a still picture.
    @MainActor static func importGIF(_ url: URL, library: LibraryModel, display: CGSize, name: String?) async throws -> LibraryItem {
        let work = try library.makeWorkFolder()
        defer { LibraryModel.removeWork(work) }
        let converted = work.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).mov")
        do {
            try await Task.detached(priority: .userInitiated) { try GIFConverter.convert(url, to: converted) }.value
        } catch GIFConverter.Failure.notAnimated {
            let location = library.location
            return try await Task.detached { try LibraryModel.makeStillItem(from: url, in: location, display: display) }.value
        }
        var item = try await LibraryModel.makeItem(from: converted, in: library.location, display: display, optimize: false)
        item.name = name ?? url.deletingPathExtension().lastPathComponent
        item.originalBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return item
    }
}
