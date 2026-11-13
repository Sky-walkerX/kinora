// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// A Kinora wallpaper package: a folder with a `wallpaper.json` manifest and the files it
/// names, shared as a zip. Anyone can make one; installing needs no account, store or purchase.
/// See docs/FORMAT.md. Packages hold media and settings only, never code: a package can tint one
/// of Kinora's originals, but not bring a shader of its own.
public struct PackageManifest: Codable, Equatable, Sendable {
    public static let format = "kinora.wallpaper"
    public static let currentFormatVersion = 1
    public static let fileName = "wallpaper.json"

    public var format: String
    public var formatVersion: Int
    /// Reverse-DNS, lower case, such as `io.github.someone.ocean-dusk`.
    public var id: String
    /// The creator's own version of this wallpaper, such as `1.0.0`.
    public var version: String
    public var name: String
    public var summary: String?
    public var author: Author
    /// An SPDX license identifier, such as `CC-BY-4.0`.
    public var license: String
    /// The credit line the license asks for. Required for licenses that require attribution.
    public var attribution: String?
    /// Where the work comes from, https only.
    public var source: URL?
    public var type: ContentType
    public var video: Media?
    public var image: Media?
    public var original: OriginalPreset?
    public var preview: String?
    public var compatibility: Compatibility?
    public var tags: [String]?

    public struct Author: Codable, Equatable, Sendable {
        public var name: String
        public var url: URL?
        public init(name: String, url: URL? = nil) {
            self.name = name
            self.url = url
        }
    }

    public enum ContentType: String, Codable, Sendable {
        case video, image, original
    }

    public struct Media: Codable, Equatable, Sendable {
        public var file: String
        public init(file: String) { self.file = file }
    }

    public struct Compatibility: Codable, Equatable, Sendable {
        /// The oldest Kinora that shows it correctly, such as `0.2.0`.
        public var minimumKinora: String?
        public init(minimumKinora: String? = nil) { self.minimumKinora = minimumKinora }
    }

    public init(id: String, version: String = "1.0.0", name: String, author: Author, license: String, type: ContentType) {
        self.format = Self.format
        self.formatVersion = Self.currentFormatVersion
        self.id = id
        self.version = version
        self.name = name
        self.author = author
        self.license = license
        self.type = type
    }

    /// The file holding the wallpaper's picture, for video and image packages.
    public var mediaFile: String? {
        switch type {
        case .video: video?.file
        case .image: image?.file
        case .original: nil
        }
    }

    /// Every file the manifest names.
    public var referencedFiles: [String] {
        [mediaFile, preview].compactMap { $0 }
    }
}

/// A built-in original with its own colours. Settings, not code.
public struct OriginalPreset: Codable, Equatable, Sendable {
    /// The original's slug, such as `aurora`.
    public var base: String
    /// Three RGB colours, each component 0...1.
    public var palette: [[Double]]?

    public init(base: String, palette: [[Double]]? = nil) {
        self.base = base
        self.palette = palette
    }

    /// The original with this preset's colours and the given identity.
    public func resolved(id: UUID, name: String) -> KinoraOriginal? {
        guard var original = KinoraOriginals.all.first(where: { $0.slug == base }) else { return nil }
        original.id = id
        original.name = name
        if let palette, palette.count == 3, palette.allSatisfy({ $0.count == 3 }) {
            original.palette = palette.map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) }
        }
        return original
    }
}

/// The limits every package must keep. Generous for real wallpapers, small enough that a
/// hostile package cannot fill the disk or memory.
public enum PackageLimits {
    public static let manifestBytes = 64 * 1024
    public static let videoBytes: Int64 = 1024 * 1024 * 1024
    public static let imageBytes: Int64 = 100 * 1024 * 1024
    public static let previewBytes: Int64 = 10 * 1024 * 1024
    public static let documentBytes: Int64 = 256 * 1024
    public static let totalBytes: Int64 = 1100 * 1024 * 1024
    public static let fileCount = 8
    public static let nameLength = 80
    public static let summaryLength = 300
    public static let authorLength = 100
    public static let attributionLength = 500
    public static let tagCount = 10
    public static let tagLength = 32
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    public static let imageExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
    /// Plain-text files a package may carry beside its media.
    public static let documents: Set<String> = ["LICENSE", "LICENSE.txt", "LICENSE.md", "README.md", "README.txt", "CREDITS.txt"]
}

/// Licenses the gallery accepts: free to redistribute, including in a wallpaper app.
public enum RedistributableLicenses {
    public static let all: Set<String> = ["CC0-1.0", "CC-BY-4.0", "CC-BY-SA-4.0", "PDDL-1.0", "LicenseRef-Public-Domain"]
    /// Those that require a credit line.
    public static let needingAttribution: Set<String> = ["CC-BY-4.0", "CC-BY-SA-4.0"]
}

/// One file in a package folder, as the installer found it on disk.
public struct PackageFile: Equatable, Sendable {
    public var name: String
    public var bytes: Int64
    public var isRegularFile: Bool
    public var isSymbolicLink: Bool
    public var isExecutable: Bool

    public init(name: String, bytes: Int64, isRegularFile: Bool = true, isSymbolicLink: Bool = false, isExecutable: Bool = false) {
        self.name = name
        self.bytes = bytes
        self.isRegularFile = isRegularFile
        self.isSymbolicLink = isSymbolicLink
        self.isExecutable = isExecutable
    }
}

public enum PackageProblem: Error, Equatable, Sendable, CustomStringConvertible {
    case noManifest
    case manifestTooLarge
    case manifestUnreadable(String)
    case wrongFormat
    case newerFormat(Int)
    case invalidField(String)
    case missingFile(String)
    case unexpectedFile(String)
    case unsafeFile(String)
    case wrongFileType(String)
    case tooLarge(String)
    case tooManyFiles
    case unknownOriginal(String)
    case needsNewerKinora(String)
    case licenseNotRedistributable(String)
    case attributionRequired

    public var description: String {
        switch self {
        case .noManifest: "It has no wallpaper.json."
        case .manifestTooLarge: "Its wallpaper.json is larger than 64 KB."
        case .manifestUnreadable(let detail): "Its wallpaper.json can't be read: \(detail)."
        case .wrongFormat: "It isn't a Kinora wallpaper."
        case .newerFormat(let version): "It uses version \(version) of the wallpaper format, which needs a newer Kinora."
        case .invalidField(let field): "Its “\(field)” is missing or not valid."
        case .missingFile(let name): "It names \(name), which isn't in the package."
        case .unexpectedFile(let name): "It contains \(name), which the manifest doesn't name."
        case .unsafeFile(let name): "It contains \(name), which is a link, folder or program; packages may only hold media."
        case .wrongFileType(let name): "\(name) isn't a kind of file Kinora accepts there."
        case .tooLarge(let name): "\(name) is larger than Kinora allows."
        case .tooManyFiles: "It has more files than a wallpaper needs."
        case .unknownOriginal(let base): "It's based on “\(base)”, which this version of Kinora doesn't have."
        case .needsNewerKinora(let version): "It needs Kinora \(version) or later."
        case .licenseNotRedistributable(let license): "Its license, \(license), doesn't allow the gallery to share it."
        case .attributionRequired: "Its license requires a credit line, and it has none."
        }
    }
}

public enum PackageValidation {
    /// Decodes and checks a manifest's own fields.
    public static func manifest(_ data: Data, kinoraVersion: String) throws -> PackageManifest {
        guard data.count <= PackageLimits.manifestBytes else { throw PackageProblem.manifestTooLarge }
        // The format fields first, so a future version gets a clear message, not a decoding error.
        if let header = try? JSONDecoder().decode(Header.self, from: data) {
            guard header.format == PackageManifest.format else { throw PackageProblem.wrongFormat }
            guard header.formatVersion <= PackageManifest.currentFormatVersion else { throw PackageProblem.newerFormat(header.formatVersion) }
        }
        let manifest: PackageManifest
        do {
            manifest = try JSONDecoder().decode(PackageManifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw PackageProblem.invalidField(key.stringValue)
        } catch let DecodingError.dataCorrupted(context) {
            throw PackageProblem.manifestUnreadable(context.debugDescription)
        } catch let DecodingError.typeMismatch(_, context) {
            throw PackageProblem.invalidField(context.codingPath.map(\.stringValue).joined(separator: "."))
        } catch let DecodingError.valueNotFound(_, context) {
            throw PackageProblem.invalidField(context.codingPath.map(\.stringValue).joined(separator: "."))
        } catch {
            throw PackageProblem.manifestUnreadable(String(describing: error))
        }
        guard manifest.format == PackageManifest.format else { throw PackageProblem.wrongFormat }
        guard manifest.formatVersion >= 1 else { throw PackageProblem.invalidField("formatVersion") }
        try checkFields(manifest)
        if let minimum = manifest.compatibility?.minimumKinora {
            guard Version(minimum) != nil else { throw PackageProblem.invalidField("compatibility.minimumKinora") }
            if let need = Version(minimum), let have = Version(kinoraVersion), have < need { throw PackageProblem.needsNewerKinora(minimum) }
        }
        return manifest
    }

    /// Checks the files beside a manifest: every named file present and of the right type and
    /// size, nothing else but plain documents, and no links, folders or programs.
    public static func files(_ files: [PackageFile], for manifest: PackageManifest) throws {
        guard files.count <= PackageLimits.fileCount + PackageLimits.documents.count else { throw PackageProblem.tooManyFiles }
        var byName: [String: PackageFile] = [:]
        for file in files where file.name != PackageManifest.fileName {
            guard isPlainFileName(file.name), !file.name.hasPrefix(".") else { throw PackageProblem.unsafeFile(file.name) }
            guard file.isRegularFile, !file.isSymbolicLink, !file.isExecutable else { throw PackageProblem.unsafeFile(file.name) }
            byName[file.name] = file
        }
        var total: Int64 = 0
        for file in byName.values { total += max(0, file.bytes) }
        guard total <= PackageLimits.totalBytes else { throw PackageProblem.tooLarge("The package") }

        let referenced = Set(manifest.referencedFiles)
        for name in byName.keys where !referenced.contains(name) {
            guard PackageLimits.documents.contains(name) else { throw PackageProblem.unexpectedFile(name) }
            if let file = byName[name], file.bytes > PackageLimits.documentBytes { throw PackageProblem.tooLarge(name) }
        }
        func check(_ name: String, extensions: Set<String>, limit: Int64) throws {
            guard let file = byName[name] else { throw PackageProblem.missingFile(name) }
            guard extensions.contains(fileExtension(name)) else { throw PackageProblem.wrongFileType(name) }
            guard file.bytes > 0, file.bytes <= limit else { throw PackageProblem.tooLarge(name) }
        }
        switch manifest.type {
        case .video:
            guard let file = manifest.video?.file else { throw PackageProblem.invalidField("video.file") }
            try check(file, extensions: PackageLimits.videoExtensions, limit: PackageLimits.videoBytes)
        case .image:
            guard let file = manifest.image?.file else { throw PackageProblem.invalidField("image.file") }
            try check(file, extensions: PackageLimits.imageExtensions, limit: PackageLimits.imageBytes)
        case .original:
            break
        }
        if let preview = manifest.preview {
            try check(preview, extensions: PackageLimits.imageExtensions, limit: PackageLimits.previewBytes)
        }
    }

    /// The stricter rule for the gallery: only licenses that allow redistribution, with credit.
    public static func galleryLicense(_ manifest: PackageManifest) throws {
        guard RedistributableLicenses.all.contains(manifest.license) else { throw PackageProblem.licenseNotRedistributable(manifest.license) }
        if RedistributableLicenses.needingAttribution.contains(manifest.license),
           (manifest.attribution ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PackageProblem.attributionRequired
        }
    }

    /// `io.github.someone.ocean-dusk`: two to eight dot-separated parts of lower-case letters,
    /// digits and hyphens.
    public static func isValidID(_ id: String) -> Bool {
        guard id.count >= 3, id.count <= 100 else { return false }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 8 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 40 && !part.hasPrefix("-") && !part.hasSuffix("-")
                && part.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    // MARK: - Internals

    private struct Header: Decodable {
        var format: String
        var formatVersion: Int
    }

    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    static func checkFields(_ m: PackageManifest) throws {
        func text(_ value: String?, _ field: String, max: Int, required: Bool = true) throws {
            guard let value else {
                if required { throw PackageProblem.invalidField(field) }
                return
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || !required, value.count <= max,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" })
            else { throw PackageProblem.invalidField(field) }
        }
        guard isValidID(m.id) else { throw PackageProblem.invalidField("id") }
        guard Version(m.version) != nil else { throw PackageProblem.invalidField("version") }
        try text(m.name, "name", max: PackageLimits.nameLength)
        try text(m.summary, "summary", max: PackageLimits.summaryLength, required: false)
        try text(m.author.name, "author.name", max: PackageLimits.authorLength)
        try text(m.attribution, "attribution", max: PackageLimits.attributionLength, required: false)
        try text(m.license, "license", max: 64)
        guard m.license.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw PackageProblem.invalidField("license")
        }
        for (url, field) in [(m.source, "source"), (m.author.url, "author.url")] {
            if let url, url.scheme?.lowercased() != "https" || url.host == nil { throw PackageProblem.invalidField(field) }
        }
        if let tags = m.tags {
            guard tags.count <= PackageLimits.tagCount, tags.allSatisfy({ !$0.isEmpty && $0.count <= PackageLimits.tagLength }) else {
                throw PackageProblem.invalidField("tags")
            }
        }
        if let preview = m.preview, !isPlainFileName(preview) { throw PackageProblem.invalidField("preview") }
        switch m.type {
        case .video:
            guard let file = m.video?.file, isPlainFileName(file) else { throw PackageProblem.invalidField("video.file") }
        case .image:
            guard let file = m.image?.file, isPlainFileName(file) else { throw PackageProblem.invalidField("image.file") }
        case .original:
            guard let preset = m.original else { throw PackageProblem.invalidField("original") }
            guard KinoraOriginals.all.contains(where: { $0.slug == preset.base }) else { throw PackageProblem.unknownOriginal(preset.base) }
            if let palette = preset.palette {
                guard palette.count == 3, palette.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } }) else {
                    throw PackageProblem.invalidField("original.palette")
                }
            }
        }
    }
}

/// A dotted version such as `1.2.0`: up to four numbers, compared numerically.
public struct Version: Comparable, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 6, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(piece) else { return nil }
            parts.append(value)
        }
        self.parts = parts
    }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}

/// Facts about a package's zip, measured before it is opened.
public enum PackageArchive {
    public struct Totals: Equatable, Sendable {
        public var files: Int
        public var bytes: Int64
    }

    /// The totals line `zipinfo -t` prints: "3 files, 20512 bytes uncompressed, 20000 bytes compressed:  2.5%".
    public static func zipTotals(_ output: String) -> Totals? {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("bytes uncompressed") }) else { return nil }
        let words = line.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
        guard let files = words.first.flatMap({ Int($0) }), files >= 0,
              let index = words.firstIndex(where: { $0.hasPrefix("uncompressed") }), index >= 2,
              let bytes = Int64(words[index - 2]), bytes >= 0 else { return nil }
        return Totals(files: files, bytes: bytes)
    }
}
