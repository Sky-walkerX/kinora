// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// One wallpaper in the user's library.
public struct LibraryItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case video
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// File name inside the library's media folder.
    public var media: String
    /// File name inside the library's thumbnails folder.
    public var thumbnail: String
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, kind: Kind, media: String, thumbnail: String, addedAt: Date) {
        self.id = id
        self.name = name
        self.kind = kind
        self.media = media
        self.thumbnail = thumbnail
        self.addedAt = addedAt
    }
}

/// The library's index file. The app writes it; the plug-in only reads it.
public struct LibraryIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var items: [LibraryItem]

    public init(items: [LibraryItem] = []) {
        self.version = Self.currentVersion
        self.items = items
    }

    public func item(_ id: UUID) -> LibraryItem? { items.first { $0.id == id } }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Items that fail to decode are skipped rather than losing the whole library.
    public static func decode(_ data: Data) -> LibraryIndex? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? decoder.decode(LossyIndex.self, from: data) else { return nil }
        // An item naming a path instead of a file in the library folder is dropped, so a damaged
        // or tampered index cannot point Kinora at files outside the library.
        let items = raw.items.compactMap(\.value).filter { isPlainFileName($0.media) && isPlainFileName($0.thumbnail) }
        var index = LibraryIndex(items: items)
        index.version = raw.version
        return index
    }

    private struct LossyIndex: Decodable {
        var version: Int
        var items: [Lossy<LibraryItem>]
    }

    private struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}

/// True for a single file name: not empty, no path separators, not "." or "..".
public func isPlainFileName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && !name.hasPrefix("~")
}

/// Where the library lives. The sandboxed plug-in reads it through a home-relative exception,
/// so paths must be built from the real home folder, not the sandbox container's.
public struct LibraryLocation: Equatable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public init(home: URL) {
        self.init(root: home.appendingPathComponent(KinoraIdentity.libraryRelativePath, isDirectory: true))
    }

    /// The location for this user, correct both inside and outside a sandbox.
    public static var current: LibraryLocation { LibraryLocation(home: realHomeDirectory()) }

    public var index: URL { root.appendingPathComponent("library.json") }
    public var settings: URL { root.appendingPathComponent("settings.json") }
    public var mediaFolder: URL { root.appendingPathComponent("Media", isDirectory: true) }
    public var thumbnailFolder: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var backupFolder: URL { root.appendingPathComponent("Backups", isDirectory: true) }

    public func mediaURL(for item: LibraryItem) -> URL { mediaFolder.appendingPathComponent(item.media) }
    public func thumbnailURL(for item: LibraryItem) -> URL { thumbnailFolder.appendingPathComponent(item.thumbnail) }
}

/// The user's real home folder. In a sandbox, `NSHomeDirectory()` points into the container.
public func realHomeDirectory() -> URL {
    if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}
