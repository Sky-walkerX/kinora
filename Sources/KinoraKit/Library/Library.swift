// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// One wallpaper in the user's library.
public struct LibraryItem: Codable, Identifiable, Equatable, Sendable {
    /// What the item is. Kinds this version does not know are kept as they are, so an older
    /// Kinora that reads a newer library neither drops the item nor loses its kind on save.
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// A video the user imported, kept in the library's media folder.
        public static let video = Kind(rawValue: "video")
        /// A still photo Kinora turned into a looping video. Plays like any video.
        public static let livingPhoto = Kind(rawValue: "livingPhoto")
        /// One of Apple's aerials that macOS already downloaded. Played where macOS keeps it,
        /// never copied, and never deleted by Kinora.
        public static let appleAerial = Kind(rawValue: "appleAerial")
        /// A wallpaper installed from a Kinora wallpaper package or the gallery.
        public static let package = Kind(rawValue: "package")
        /// One of Kinora's built-in generative wallpapers. Never stored in the index.
        public static let original = Kind(rawValue: "original")
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// File name inside the library's media folder.
    public var media: String
    /// File name inside the library's thumbnails folder.
    public var thumbnail: String
    public var addedAt: Date
    /// Size of the file the user imported, and of the file Kinora keeps, when known.
    public var originalBytes: Int64?
    public var storedBytes: Int64?

    public init(id: UUID = UUID(), name: String, kind: Kind, media: String, thumbnail: String, addedAt: Date,
                originalBytes: Int64? = nil, storedBytes: Int64? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.media = media
        self.thumbnail = thumbnail
        self.addedAt = addedAt
        self.originalBytes = originalBytes
        self.storedBytes = storedBytes
    }

    /// Disk space the optimization saved, when it saved any.
    public var savedBytes: Int64 {
        guard ownsMedia, let originalBytes, let storedBytes, originalBytes > storedBytes else { return 0 }
        return originalBytes - storedBytes
    }

    /// False for media Kinora only points at, such as Apple's aerials. Kinora never deletes those.
    public var ownsMedia: Bool { kind != .appleAerial && kind != .original }

    /// True for items the user may rename and remove.
    public var isEditable: Bool { kind != .original }

    /// Credit for content made by someone else, shown wherever the item is.
    public var attribution: Attribution?

    public struct Attribution: Codable, Equatable, Sendable {
        public var author: String?
        /// An SPDX identifier or a short license name, such as "CC-BY-4.0".
        public var license: String?
        public var source: URL?
        public init(author: String? = nil, license: String? = nil, source: URL? = nil) {
            self.author = author
            self.license = license
            self.source = source
        }
    }
}

/// A named, ordered set of library items to rotate through.
public struct Playlist: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [UUID]

    public init(id: UUID = UUID(), name: String, items: [UUID] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

/// The library's index file. The app writes it; the plug-in only reads it.
public struct LibraryIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var items: [LibraryItem]
    /// Absent in libraries written before playlists existed.
    public var playlists: [Playlist]?

    public init(items: [LibraryItem] = [], playlists: [Playlist]? = nil) {
        self.version = Self.currentVersion
        self.items = items
        self.playlists = playlists
    }

    public func item(_ id: UUID) -> LibraryItem? { items.first { $0.id == id } }

    /// The library without `id`, and without it in any playlist.
    public func removing(_ id: UUID) -> LibraryIndex {
        var index = self
        index.items.removeAll { $0.id == id }
        index.playlists = playlists?.map { playlist in
            var playlist = playlist
            playlist.items.removeAll { $0 == id }
            return playlist
        }
        return index
    }

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
        let known = Set(items.map(\.id)).union(KinoraOriginals.all.map(\.id))
        // Playlists keep only items that still exist, in their order, once each.
        let playlists = raw.playlists?.compactMap(\.value).map { playlist -> Playlist in
            var seen: Set<UUID> = []
            var playlist = playlist
            playlist.items = playlist.items.filter { known.contains($0) && seen.insert($0).inserted }
            return playlist
        }
        var index = LibraryIndex(items: items, playlists: playlists)
        index.version = raw.version
        return index
    }

    private struct LossyIndex: Decodable {
        var version: Int
        var items: [Lossy<LibraryItem>]
        var playlists: [Lossy<Playlist>]?
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
    /// Kinora's live selection, followed by choices made with "Use as Wallpaper".
    public var selection: URL { root.appendingPathComponent("selection.json") }
    public var mediaFolder: URL { root.appendingPathComponent("Media", isDirectory: true) }
    public var thumbnailFolder: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var backupFolder: URL { root.appendingPathComponent("Backups", isDirectory: true) }

    /// Packages installed from files or the gallery, one folder each.
    public var packagesFolder: URL { root.appendingPathComponent("Packages", isDirectory: true) }
    /// Work in progress, such as a Living Photo being rendered or a download. Cleared at launch.
    public var workFolder: URL { root.appendingPathComponent("Work", isDirectory: true) }

    /// Where an item's video is. Apple's aerials stay where macOS keeps them.
    public func mediaURL(for item: LibraryItem, home: URL = realHomeDirectory()) -> URL {
        if item.kind == .appleAerial { return AppleAerials.videoURL(fileName: item.media, home: home) }
        return mediaFolder.appendingPathComponent(item.media)
    }

    /// The item's media when Kinora owns it and may delete it; nil for media it only points at.
    public func ownedMediaURL(for item: LibraryItem) -> URL? {
        item.ownsMedia ? mediaFolder.appendingPathComponent(item.media) : nil
    }

    public func thumbnailURL(for item: LibraryItem) -> URL { thumbnailFolder.appendingPathComponent(item.thumbnail) }
}

/// The user's real home folder. In a sandbox, `NSHomeDirectory()` points into the container.
public func realHomeDirectory() -> URL {
    if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}
