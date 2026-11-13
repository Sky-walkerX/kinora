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

    /// The kind of manifest at `url`, a folder or a zip, if any. Zips are recognised by name only
    /// here; they are measured and checked when imported.
    static func manifest(at url: URL) -> ForeignWallpaper.Source? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue {
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            return ForeignWallpaper.manifest(in: names)?.source
        }
        guard url.pathExtension.lowercased() == "zip" else { return nil }
        // A zip holding a Lively manifest, by its listing, without extracting anything.
        let listing = Shell.run("/usr/bin/zipinfo", ["-1", url.path])
        guard listing.status == 0 else { return nil }
        let names = Set(listing.output.split(separator: "\n").map { ($0 as Substring).split(separator: "/").last.map(String.init) ?? "" })
        return ForeignWallpaper.manifest(in: names)?.source
    }

    @MainActor static func importWallpaper(at url: URL, manifest source: ForeignWallpaper.Source, library: LibraryModel,
                                           display: CGSize) async throws -> LibraryItem {
        let work = try library.makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let manifestName = source == .lively ? ForeignWallpaper.livelyManifest : ForeignWallpaper.wallpaperEngineManifest
        let folder = try await Task.detached { try PackageInstaller.root(for: url, work: work, manifests: [manifestName]) }.value
        let displayName = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)),
              let wallpaper = ForeignWallpaper.parse(data, source: source, folderName: displayName)
        else { throw Failure.unreadable(displayName) }
        let file: String
        switch ForeignWallpaper.support(wallpaper) {
        case .success(let path): file = path
        case .failure(let reason): throw Failure.unsupported(wallpaper.title, reason)
        }
        // The file must really be inside the folder, after following any links.
        let media = folder.appendingPathComponent(file).resolvingSymlinksInPath()
        let base = folder.resolvingSymlinksInPath().path + "/"
        var isFolder: ObjCBool = false
        guard media.path.hasPrefix(base), FileManager.default.fileExists(atPath: media.path, isDirectory: &isFolder), !isFolder.boolValue else {
            throw Failure.missingFile(wallpaper.title)
        }

        var item: LibraryItem
        switch wallpaper.kind {
        case .gif:
            item = try await importGIF(media, library: library, display: display, name: wallpaper.title)
        case .picture:
            let location = library.location
            item = try await Task.detached { try LibraryModel.makeStillItem(from: media, in: location, display: display) }.value
        default:
            item = try await LibraryModel.makeItem(from: media, in: library.location, display: display)
        }
        item.name = wallpaper.title
        item.attribution = LibraryItem.Attribution(
            author: wallpaper.author,
            license: wallpaper.license ?? (source == .wallpaperEngine ? "From Wallpaper Engine; for your own use" : nil))
        return item
    }

    /// Converts an animated GIF to video once; a single-frame GIF becomes a still picture.
    @MainActor static func importGIF(_ url: URL, library: LibraryModel, display: CGSize, name: String?) async throws -> LibraryItem {
        let work = try library.makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
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
