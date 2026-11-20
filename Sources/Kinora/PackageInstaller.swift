// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import Foundation
import ImageIO
import KinoraKit
import KinoraMedia
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
        defer { LibraryModel.removeWork(work) }
        let source = try await background {
            try PackageSource.open(url, work: work, manifests: [PackageManifest.fileName], maxEntries: 64, maxDepth: 2)
        }

        let manifest: PackageManifest
        do {
            let data = try source.read(PackageManifest.fileName, limit: PackageLimits.manifestBytes)
            manifest = try PackageValidation.manifest(data, kinoraVersion: kinoraVersion)
            try PackageValidation.files(source.listing(), for: manifest)
            if let expected {
                try PackageValidation.galleryLicense(manifest)
                guard manifest.id == expected.id, manifest.version == expected.version, manifest.license == expected.license else {
                    throw Failure.wrongPackage
                }
            }
        } catch let problem as PackageProblem {
            throw Failure.invalid(problem)
        }
        try Task.checkCancellation()

        // A package replaces the one installed from the same place: the gallery's from the
        // gallery, a file's from a file. A file never silently takes over a gallery item.
        let origin = expected.map { "gallery:\($0.sha256)" } ?? "file"
        let existing = library.items.first { $0.packageID == manifest.id && ($0.packageOrigin ?? "file").hasPrefix(expected == nil ? "file" : "gallery:") }
        var item = try await makeItem(manifest, source: source, work: work, library: library, id: existing?.id ?? UUID())
        try Task.checkCancellation()
        item.attribution = LibraryItem.Attribution(author: manifest.author.name, license: manifest.license,
                                                   source: manifest.source ?? manifest.author.url)
        if let attribution = manifest.attribution, !attribution.isEmpty { item.attribution?.author = attribution }
        item.packageID = manifest.id
        item.packageVersion = manifest.version
        item.packageOrigin = origin
        if let existing { library.replace(existing, with: item) } else { library.add(item) }
        return item
    }

    /// Runs blocking file work off the main actor but in the calling task, so cancelling the
    /// task (the gallery's Cancel button) reaches it, unlike work in a detached task.
    static func background<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try body()
    }

    // MARK: - Making the library item

    @MainActor static func makeItem(_ manifest: PackageManifest, source: PackageSource, work: URL, library: LibraryModel,
                                    id: UUID) async throws -> LibraryItem {
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
            let media = try await background { try source.file(file, work: work, limit: PackageLimits.videoBytes) }
            try await checkVideo(media)
            var item = try await LibraryModel.makeItem(from: media, in: location, display: VideoOptimizer.largestDisplayPixels(), id: id,
                                                       stem: stem)
            item.name = manifest.name
            item.kind = .package
            return item
        case .image:
            guard let file = manifest.image?.file else { throw Failure.invalid(.invalidField("image.file")) }
            let display = VideoOptimizer.largestDisplayPixels()
            var item = try await background {
                let media = try source.file(file, work: work, limit: PackageLimits.imageBytes)
                return try LibraryModel.makeStillItem(from: media, in: location, display: display, id: id, stem: stem,
                                                      allowedTypes: LibraryModel.packageImageTypes)
            }
            item.name = manifest.name
            item.kind = .package
            return item
        }
    }

    /// A video Kinora will play: openable, with a video track, at most 8K and ten minutes.
    static func checkVideo(_ url: URL) async throws {
        let asset = LibraryModel.localAsset(url)
        let playable: Bool
        do { playable = try await asset.load(.isPlayable) } catch is CancellationError { throw CancellationError() } catch { playable = false }
        try Task.checkCancellation()
        guard playable,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let duration = try? await asset.load(.duration),
              max(abs(size.width), abs(size.height)) <= 8192, duration.seconds > 0, duration.seconds <= 600
        else { throw Failure.unplayable }
    }
}
