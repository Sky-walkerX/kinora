// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

public enum WallpaperStoreError: Error, Equatable {
    case noStore
    case unreadable(String)
    case validationFailed(String)
}

/// Reads, backs up and writes WallpaperAgent's store files. Every write is preceded by a
/// backup: the first copy Kinora ever made is kept forever as `original-<name>`, and the copy
/// before the latest write as `previous-<name>`.
public struct WallpaperStoreFiles: Sendable {
    /// macOS 27 keeps the live store in `Index.plist`; some Macs also carry `Index_v2.plist`.
    /// Both are edited so the choice holds whichever one WallpaperAgent reads.
    public static let fileNames = ["Index.plist", "Index_v2.plist"]

    public let storeFolder: URL
    public let backupFolder: URL

    public init(storeFolder: URL, backupFolder: URL) {
        self.storeFolder = storeFolder
        self.backupFolder = backupFolder
    }

    public static func current(library: LibraryLocation = .current) -> WallpaperStoreFiles {
        WallpaperStoreFiles(
            storeFolder: realHomeDirectory().appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store", isDirectory: true),
            backupFolder: library.backupFolder
        )
    }

    public var existingFiles: [URL] {
        Self.fileNames.map { storeFolder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The store macOS reads, `Index.plist` when present.
    public var primaryFile: URL? { existingFiles.first }

    public func read(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw WallpaperStoreError.unreadable(url.lastPathComponent) }
        return plist
    }

    public func readPrimary() throws -> [String: Any] {
        guard let url = primaryFile else { throw WallpaperStoreError.noStore }
        return try read(url)
    }

    /// Applies `edit` to every store file, after backing each one up. Returns the files written.
    @discardableResult
    public func apply(_ edit: ([String: Any]) -> [String: Any]) throws -> [URL] {
        let files = existingFiles
        guard !files.isEmpty else { throw WallpaperStoreError.noStore }
        // Read everything first, so an unreadable file stops the change before anything is written.
        let stores = try files.map { try read($0) }
        try backUp(files)
        for (url, store) in zip(files, stores) { try write(edit(store), to: url) }
        return files
    }

    public var hasOriginalBackup: Bool {
        Self.fileNames.contains { FileManager.default.fileExists(atPath: backup("original", $0).path) }
    }

    /// Puts back the store as it was before Kinora first changed it. Returns false when there
    /// is no such backup.
    @discardableResult
    public func restoreOriginal() throws -> Bool {
        var restored = false
        for name in Self.fileNames {
            let source = backup("original", name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let store = try read(source)
            try write(store, to: storeFolder.appendingPathComponent(name))
            restored = true
        }
        return restored
    }

    // MARK: - Internals

    func backup(_ kind: String, _ name: String) -> URL { backupFolder.appendingPathComponent("\(kind)-\(name)") }

    func backUp(_ files: [URL]) throws {
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        for url in files {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let original = backup("original", name)
            if !FileManager.default.fileExists(atPath: original.path) { try data.write(to: original, options: .atomic) }
            try data.write(to: backup("previous", name), options: .atomic)
        }
    }

    /// Writes a binary plist atomically, then reads it back to prove it parses.
    func write(_ store: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
        guard (try? read(url)) != nil else { throw WallpaperStoreError.validationFailed(url.lastPathComponent) }
    }
}
