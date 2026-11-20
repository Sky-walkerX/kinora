// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import KinoraKit

/// Where an untrusted wallpaper's files come from: a folder the user chose, or a zip Kinora
/// reads itself. Either way only the files asked for are ever read, each must be a plain file
/// inside the wallpaper, and each is read under a size limit.
///
/// A zip is first copied into Kinora's work folder, so it is measured and read as one file that
/// can't change underneath. Nothing in it is written anywhere until `file(_:work:limit:)` asks
/// for one entry, which is then written under a name Kinora chooses.
public enum PackageSource: @unchecked Sendable {
    case folder(URL)
    case archive(ZipArchive, prefix: String)

    public enum Failure: LocalizedError, Equatable {
        case notFound
        case tooLarge
        case damaged(String)
        case unsafe(String)

        public var errorDescription: String? {
            switch self {
            case .notFound: "Kinora couldn't find the wallpaper's settings file."
            case .tooLarge: "This wallpaper is larger than Kinora allows."
            case .damaged(let detail): "Kinora couldn't open this archive: \(detail)."
            case .unsafe(let name): "It contains \(name), which is a link or a special file; Kinora only reads plain files."
            }
        }
    }

    /// Opens `url`, a folder or a zip, and finds the folder holding one of `manifests`: the top
    /// level or its only folder. `maxDepth` limits how deep any entry of a zip may be.
    public static func open(_ url: URL, work: URL, manifests: [String], maxEntries: Int, maxDepth: Int) throws -> PackageSource {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { throw Failure.notFound }
        if isFolder.boolValue {
            let source = PackageSource.folder(url)
            guard manifests.contains(where: source.contains) else { throw Failure.notFound }
            return source
        }
        let copy = work.appendingPathComponent("archive.zip")
        try copyRegularFile(url, to: copy, limit: PackageLimits.totalBytes)
        let archive: ZipArchive
        do { archive = try ZipArchive(url: copy, maxEntries: maxEntries) } catch { throw describe(error) }

        var topLevel: Set<String> = []
        for entry in archive.entries where !entry.isMetadata {
            let parts = entry.components
            guard !entry.isSymbolicLink, !entry.isSpecial else { throw Failure.unsafe(parts.last ?? entry.path) }
            guard !entry.isEncrypted else { throw Failure.damaged("it is encrypted") }
            guard ZipArchive.isSafePath(entry.path), parts.count <= maxDepth else { throw Failure.unsafe(entry.path) }
            if let first = parts.first { topLevel.insert(first) }
        }
        let declared = archive.entries.reduce(Int64(0)) { $0 + ($1.isMetadata ? 0 : $1.size) }
        guard declared <= PackageLimits.totalBytes else { throw Failure.tooLarge }

        for prefix in [""] + (topLevel.count == 1 ? ["\(topLevel.first!)/"] : []) {
            let source = PackageSource.archive(archive, prefix: prefix)
            if manifests.contains(where: source.contains) { return source }
        }
        throw Failure.notFound
    }

    /// True when the wallpaper has a plain file at `relative`.
    public func contains(_ relative: String) -> Bool {
        switch self {
        case .folder(let root):
            return (try? Self.resolve(relative, in: root)) != nil
        case .archive(let archive, let prefix):
            guard let entry = archive.entry(prefix + relative) else { return false }
            return !entry.isDirectory && !entry.isSpecial && !entry.isMetadata
        }
    }

    /// A small file's bytes, such as a manifest.
    public func read(_ relative: String, limit: Int) throws -> Data {
        switch self {
        case .folder(let root):
            let url = try Self.resolve(relative, in: root)
            guard let size = Self.size(url), size <= Int64(limit) else { throw PackageProblem.manifestTooLarge }
            guard let handle = try? FileHandle(forReadingFrom: url) else { throw PackageProblem.noManifest }
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw PackageProblem.manifestTooLarge }
            return data
        case .archive(let archive, let prefix):
            guard let entry = archive.entry(prefix + relative), !entry.isDirectory else { throw PackageProblem.noManifest }
            guard entry.size <= Int64(limit) else { throw PackageProblem.manifestTooLarge }
            do { return try archive.data(entry, limit: limit) } catch { throw Self.describe(error) }
        }
    }

    /// A file to import: inside a folder, the file itself; inside a zip, a copy written to `work`.
    public func file(_ relative: String, work: URL, limit: Int64) throws -> URL {
        switch self {
        case .folder(let root):
            let url = try Self.resolve(relative, in: root)
            guard let size = Self.size(url), size <= limit else { throw Failure.tooLarge }
            return url
        case .archive(let archive, let prefix):
            guard let entry = archive.entry(prefix + relative), !entry.isDirectory else { throw PackageProblem.missingFile(relative) }
            let ext = (relative as NSString).pathExtension.lowercased()
            let destination = work.appendingPathComponent("file-\(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)"))
            do {
                try archive.extract(entry, to: destination, limit: limit) { Task.isCancelled }
            } catch ZipArchive.Failure.cancelled {
                throw CancellationError()
            } catch {
                throw Self.describe(error)
            }
            return destination
        }
    }

    /// The wallpaper's top-level entries, as the package validator sees them. Folders, links
    /// and programs are reported so it can refuse them.
    public func listing() throws -> [PackageFile] {
        switch self {
        case .folder(let root):
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [])
            return entries.filter { $0.lastPathComponent != ".DS_Store" }.map { entry in
                let values = try? entry.resourceValues(forKeys: Set(keys))
                let permissions = ((try? FileManager.default.attributesOfItem(atPath: entry.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
                return PackageFile(name: entry.lastPathComponent, bytes: Int64(values?.fileSize ?? 0),
                                   isRegularFile: values?.isRegularFile == true, isSymbolicLink: values?.isSymbolicLink == true,
                                   isExecutable: permissions & 0o111 != 0)
            }
        case .archive(let archive, let prefix):
            let depth = prefix.isEmpty ? 0 : 1
            var files: [String: PackageFile] = [:]
            for entry in archive.entries where !entry.isMetadata && entry.path.hasPrefix(prefix) && entry.path != prefix {
                let parts = entry.components
                guard parts.count > depth else { continue }
                let name = parts[depth]
                // Anything nested deeper shows as a folder, which packages may not hold.
                let nested = parts.count > depth + 1 || entry.isDirectory
                files[name] = PackageFile(name: name, bytes: nested ? 0 : entry.size, isRegularFile: !nested && !entry.isSpecial,
                                          isSymbolicLink: entry.isSymbolicLink, isExecutable: entry.isExecutable)
            }
            return files.values.sorted { $0.name < $1.name }
        }
    }

    // MARK: - Pieces

    /// A plain file at `relative` inside `root`, after following any links, or an error.
    static func resolve(_ relative: String, in root: URL) throws -> URL {
        guard let path = ForeignWallpaper.relativePath(relative) else { throw PackageProblem.missingFile(relative) }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { throw Failure.unsafe(relative) }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
            throw PackageProblem.missingFile(relative)
        }
        return url
    }

    static func size(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey])).flatMap(\.fileSize).map(Int64.init)
    }

    /// Copies a plain file (following links to it) without reading more than `limit` bytes.
    static func copyRegularFile(_ source: URL, to destination: URL, limit: Int64) throws {
        let resolved = source.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else {
            throw Failure.notFound
        }
        guard Int64(values.fileSize ?? 0) <= limit else { throw Failure.tooLarge }
        guard let input = try? FileHandle(forReadingFrom: resolved),
              FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: destination) else { throw Failure.notFound }
        defer { try? input.close(); try? output.close() }
        var copied: Int64 = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            copied += Int64(chunk.count)
            // The file may have grown since it was measured.
            guard copied <= limit else { throw Failure.tooLarge }
            try output.write(contentsOf: chunk)
        }
    }

    static func describe(_ error: Error) -> Error {
        switch error {
        case ZipArchive.Failure.notAZip: Failure.damaged("it isn't a zip archive")
        case ZipArchive.Failure.tooManyEntries: PackageProblem.tooManyFiles
        case ZipArchive.Failure.tooLarge: Failure.tooLarge
        case ZipArchive.Failure.cancelled: CancellationError()
        case ZipArchive.Failure.unsupported(let what): Failure.damaged("Kinora doesn't read \(what)")
        case ZipArchive.Failure.damaged(let detail): Failure.damaged(detail)
        default: error
        }
    }
}
