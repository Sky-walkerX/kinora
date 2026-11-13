// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// The gallery's list of wallpapers, `catalog.json` in the kinora-gallery repository. Kinora
/// fetches it only when the user opens the gallery, and downloads only what the user picks.
public struct GalleryCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// Where the catalog is published. Nothing is fetched until the user opens the gallery.
    public static let defaultURL = URL(string: "https://raw.githubusercontent.com/Sky-walkerX/kinora-gallery/main/catalog.json")!

    public var schemaVersion: Int
    public var entries: [GalleryEntry]

    public init(entries: [GalleryEntry]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.entries = entries
    }
}

public struct GalleryEntry: Codable, Equatable, Identifiable, Sendable {
    /// The package's identifier, as in its manifest.
    public var id: String
    public var version: String
    public var name: String
    public var summary: String?
    public var type: PackageManifest.ContentType
    public var author: String
    public var license: String
    public var attribution: String?
    public var source: URL?
    /// The package zip, from the gallery's GitHub releases.
    public var download: URL
    /// Hex SHA-256 of the zip; the download is discarded unless it matches.
    public var sha256: String
    public var bytes: Int64
    public var preview: URL?
    public var width: Int?
    public var height: Int?
    public var tags: [String]?

    public init(id: String, version: String, name: String, type: PackageManifest.ContentType, author: String, license: String,
                attribution: String?, download: URL, sha256: String, bytes: Int64) {
        self.id = id
        self.version = version
        self.name = name
        self.type = type
        self.author = author
        self.license = license
        self.attribution = attribution
        self.download = download
        self.sha256 = sha256
        self.bytes = bytes
    }

    /// Wider than 21:10, for ultrawide displays.
    public var isUltrawide: Bool {
        guard let width, let height, height > 0 else { return false }
        return Double(width) / Double(height) > 2.1
    }
}

public enum GalleryValidation {
    /// Hosts the gallery's files may come from: GitHub, where the gallery repository and its
    /// releases live, including the hosts release downloads redirect to.
    public static let allowedHosts: Set<String> = [
        "github.com", "raw.githubusercontent.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    public static let catalogBytes = 2 * 1024 * 1024

    public enum Problem: Error, Equatable, Sendable {
        case tooLarge, unreadable, newerSchema(Int)
    }

    /// A URL Kinora will fetch for the gallery: https, on an allowed host, no credentials.
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        return allowedHosts.contains(host) && (url.port == nil || url.port == 443)
    }

    /// The catalog's valid entries. Entries that break a rule are left out, so one bad entry
    /// cannot hide the rest; the count of those left out is returned too.
    public static func decode(_ data: Data) throws -> (catalog: GalleryCatalog, skipped: Int) {
        guard data.count <= catalogBytes else { throw Problem.tooLarge }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw Problem.unreadable }
        guard header.schemaVersion <= GalleryCatalog.currentSchemaVersion else { throw Problem.newerSchema(header.schemaVersion) }
        let raw = header.entries ?? []
        var seen: Set<String> = []
        let valid = raw.compactMap(\.value).filter { isValid($0) && seen.insert($0.id).inserted }
        return (GalleryCatalog(entries: valid), raw.count - valid.count)
    }

    public static func isValid(_ entry: GalleryEntry) -> Bool {
        guard PackageValidation.isValidID(entry.id), Version(entry.version) != nil,
              !entry.name.trimmingCharacters(in: .whitespaces).isEmpty, entry.name.count <= PackageLimits.nameLength,
              !entry.author.trimmingCharacters(in: .whitespaces).isEmpty, entry.author.count <= PackageLimits.authorLength,
              RedistributableLicenses.all.contains(entry.license),
              isAllowed(entry.download), entry.preview.map(isAllowed) ?? true,
              entry.source.map({ $0.scheme?.lowercased() == "https" }) ?? true,
              isSHA256(entry.sha256), entry.bytes > 0, entry.bytes <= PackageLimits.totalBytes
        else { return false }
        if RedistributableLicenses.needingAttribution.contains(entry.license),
           (entry.attribution ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    public static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private struct Header: Decodable {
        var schemaVersion: Int
        var entries: [Lossy<GalleryEntry>]?
    }

    private struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}
