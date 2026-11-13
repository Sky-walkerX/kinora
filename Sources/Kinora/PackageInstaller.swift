// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import Foundation
import ImageIO
import KinoraKit
import KinoraRender
import UniformTypeIdentifiers

/// Installs Kinora wallpaper packages (docs/FORMAT.md) from a folder or a zip. Packages are
/// untrusted: everything is checked before anything is copied, archives are measured before
/// they are opened, and only the media the manifest names is ever read.
enum PackageInstaller {
    enum Failure: LocalizedError, Equatable {
        case invalid(PackageProblem)
        case archiveTooLarge
        case cannotExtract
        case unplayable
        case wrongPackage

        var errorDescription: String? {
            switch self {
            case .invalid(let problem): "This isn't a wallpaper Kinora can install. \(problem.description)"
            case .archiveTooLarge: "This package is larger than Kinora allows."
            case .cannotExtract: "Kinora couldn't open this package. It may be damaged."
            case .unplayable: "The package's video or picture can't be played on this Mac."
            case .wrongPackage: "The download doesn't match the gallery's listing, so Kinora didn't install it."
            }
        }
    }

    static let kinoraVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"

    /// Installs a package. Installing a package already in the library replaces it in place,
    /// keeping its identity so playlists, schedules and the Lock Screen still find it.
    /// `expected` holds the gallery's listing when the package came from there; the stricter
    /// gallery rules then apply.
    @MainActor static func install(_ url: URL, into library: LibraryModel, expected: GalleryEntry? = nil) async throws -> LibraryItem {
        let work = try library.makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let root = try await Task.detached { try packageRoot(for: url, work: work) }.value

        let manifestURL = root.appendingPathComponent(PackageManifest.fileName)
        guard let size = fileSize(manifestURL) else { throw Failure.invalid(.noManifest) }
        guard size <= PackageLimits.manifestBytes else { throw Failure.invalid(.manifestTooLarge) }
        let manifest: PackageManifest
        do {
            manifest = try PackageValidation.manifest(try Data(contentsOf: manifestURL), kinoraVersion: kinoraVersion)
            try PackageValidation.files(try listing(root), for: manifest)
            if let expected {
                try PackageValidation.galleryLicense(manifest)
                guard manifest.id == expected.id, manifest.license == expected.license else { throw Failure.wrongPackage }
            }
        } catch let problem as PackageProblem {
            throw Failure.invalid(problem)
        }

        let existing = library.items.first { $0.packageID == manifest.id }
        var item = try await makeItem(manifest, root: root, library: library, id: existing?.id ?? UUID())
        item.attribution = LibraryItem.Attribution(author: manifest.author.name, license: manifest.license,
                                                   source: manifest.source ?? manifest.author.url)
        if let attribution = manifest.attribution, !attribution.isEmpty { item.attribution?.author = attribution }
        item.packageID = manifest.id
        item.packageVersion = manifest.version
        if let existing { library.replace(existing, with: item) } else { library.add(item) }
        return item
    }

    // MARK: - Reading the package

    /// The folder holding `wallpaper.json`: the folder itself, or a zip extracted into `work`.
    static func packageRoot(for url: URL, work: URL) throws -> URL {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { throw Failure.invalid(.noManifest) }
        if isFolder.boolValue { return url }
        guard let bytes = fileSize(url), bytes <= PackageLimits.totalBytes else { throw Failure.archiveTooLarge }
        // Measure first: a small zip can hold gigabytes, or thousands of entries.
        let info = Shell.run("/usr/bin/zipinfo", ["-t", url.path])
        guard info.status == 0, let measured = parseZipTotals(info.output) else { throw Failure.cannotExtract }
        guard measured.files <= 32, measured.bytes <= PackageLimits.totalBytes else { throw Failure.archiveTooLarge }
        let destination = work.appendingPathComponent("extracted", isDirectory: true)
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, destination.path]).status == 0 else { throw Failure.cannotExtract }
        // No links anywhere in what came out, so nothing can point outside the package.
        if let walker = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let entry as URL in walker where (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw Failure.invalid(.unsafeFile(entry.lastPathComponent))
            }
        }
        if FileManager.default.fileExists(atPath: destination.appendingPathComponent(PackageManifest.fileName).path) { return destination }
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).filter { $0 != "__MACOSX" }
        if children.count == 1 {
            let inner = destination.appendingPathComponent(children[0], isDirectory: true)
            if FileManager.default.fileExists(atPath: inner.appendingPathComponent(PackageManifest.fileName).path) { return inner }
        }
        throw Failure.invalid(.noManifest)
    }

    static func parseZipTotals(_ output: String) -> (files: Int, bytes: Int64)? {
        PackageArchive.zipTotals(output).map { ($0.files, $0.bytes) }
    }

    /// The package folder's entries as the validator sees them. Folders, links and programs
    /// are reported so it can refuse them.
    static func listing(_ root: URL) throws -> [PackageFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [])
        return entries.filter { $0.lastPathComponent != ".DS_Store" }.map { entry in
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let permissions = ((try? FileManager.default.attributesOfItem(atPath: entry.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            return PackageFile(name: entry.lastPathComponent, bytes: Int64(values?.fileSize ?? 0),
                               isRegularFile: values?.isRegularFile == true, isSymbolicLink: values?.isSymbolicLink == true,
                               isExecutable: permissions & 0o111 != 0)
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    // MARK: - Making the library item

    @MainActor static func makeItem(_ manifest: PackageManifest, root: URL, library: LibraryModel, id: UUID) async throws -> LibraryItem {
        let location = library.location
        let fm = FileManager.default
        try fm.createDirectory(at: location.mediaFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: location.thumbnailFolder, withIntermediateDirectories: true)
        // Fresh file names, so a replaced package never overwrites files still on screen.
        let stem = "\(id.uuidString)-\(UUID().uuidString.prefix(8))"
        let thumbnail = "\(stem).png"
        switch manifest.type {
        case .original:
            guard let preset = manifest.original, let tinted = preset.resolved(id: id, name: manifest.name) else {
                throw Failure.invalid(.invalidField("original"))
            }
            var item = LibraryItem(id: id, name: manifest.name, kind: .package, media: preset.base, thumbnail: thumbnail, addedAt: Date())
            item.preset = preset
            if let renderer = OriginalRenderer.shared,
               let image = try? renderer.image(tinted, width: 1280, height: 800, time: 240, sky: .afternoon) {
                try LibraryModel.writePNG(image, to: location.thumbnailURL(for: item))
            }
            return item
        case .video:
            guard let file = manifest.video?.file else { throw Failure.invalid(.invalidField("video.file")) }
            let source = root.appendingPathComponent(file)
            try await checkVideo(source)
            var item = try await LibraryModel.makeItem(from: source, in: location, display: VideoOptimizer.largestDisplayPixels(), id: id,
                                                       stem: stem)
            item.name = manifest.name
            item.kind = .package
            return item
        case .image:
            guard let file = manifest.image?.file else { throw Failure.invalid(.invalidField("image.file")) }
            var item = try LibraryModel.makeStillItem(from: root.appendingPathComponent(file), in: location,
                                                      display: VideoOptimizer.largestDisplayPixels(), id: id, stem: stem)
            item.name = manifest.name
            item.kind = .package
            return item
        }
    }

    /// A video Kinora will play: openable, with a video track, at most 8K and ten minutes.
    static func checkVideo(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let duration = try? await asset.load(.duration),
              max(abs(size.width), abs(size.height)) <= 8192, duration.seconds > 0, duration.seconds <= 600
        else { throw Failure.unplayable }
    }
}
