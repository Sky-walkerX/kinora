// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

@Suite struct PackageManifestTests {
    func manifest(_ fields: [String: Any]) throws -> Data {
        var base: [String: Any] = [
            "format": "kinora.wallpaper", "formatVersion": 1, "id": "io.github.someone.ocean-dusk", "version": "1.0.0",
            "name": "Ocean Dusk", "author": ["name": "Someone"], "license": "CC-BY-4.0", "attribution": "Footage by Someone, CC BY 4.0",
            "type": "video", "video": ["file": "loop.mov"], "preview": "preview.jpg",
        ]
        for (key, value) in fields { base[key] = value is NSNull ? nil : value }
        return try JSONSerialization.data(withJSONObject: base)
    }

    func validate(_ fields: [String: Any] = [:]) throws -> PackageManifest {
        try PackageValidation.manifest(try manifest(fields), kinoraVersion: "0.2.0")
    }

    @Test func acceptsAWellFormedManifest() throws {
        let m = try validate()
        #expect(m.name == "Ocean Dusk")
        #expect(m.referencedFiles == ["loop.mov", "preview.jpg"])
        try PackageValidation.galleryLicense(m)
    }

    @Test func explainsFormatProblems() throws {
        #expect(throws: PackageProblem.wrongFormat) { try validate(["format": "wallpaper-engine"]) }
        #expect(throws: PackageProblem.newerFormat(2)) { try validate(["formatVersion": 2]) }
        #expect(throws: PackageProblem.invalidField("name")) { try validate(["name": NSNull()]) }
        #expect(throws: PackageProblem.manifestTooLarge) {
            try PackageValidation.manifest(Data(count: PackageLimits.manifestBytes + 1), kinoraVersion: "1.0")
        }
    }

    @Test func refusesPathsAndBadValues() throws {
        #expect(throws: PackageProblem.invalidField("video.file")) { try validate(["video": ["file": "../../.ssh/id_rsa"]]) }
        #expect(throws: PackageProblem.invalidField("video.file")) { try validate(["video": ["file": "/etc/passwd"]]) }
        #expect(throws: PackageProblem.invalidField("preview")) { try validate(["preview": "a/b.jpg"]) }
        #expect(throws: PackageProblem.invalidField("id")) { try validate(["id": "Not An ID"]) }
        #expect(throws: PackageProblem.invalidField("source")) { try validate(["source": "http://example.com/x"]) }
        #expect(throws: PackageProblem.invalidField("source")) { try validate(["source": "file:///etc/passwd"]) }
        #expect(throws: PackageProblem.invalidField("name")) { try validate(["name": String(repeating: "x", count: 81)]) }
        #expect(throws: PackageProblem.invalidField("name")) { try validate(["name": "Bad\u{0007}Name"]) }
        #expect(throws: PackageProblem.invalidField("license")) { try validate(["license": "CC BY 4.0"]) }
    }

    @Test func needsANewerKinoraWhenItSaysSo() throws {
        #expect(throws: PackageProblem.needsNewerKinora("9.0")) { try validate(["compatibility": ["minimumKinora": "9.0"]]) }
        #expect(try validate(["compatibility": ["minimumKinora": "0.1.5"]]).compatibility?.minimumKinora == "0.1.5")
    }

    @Test func presetsTintAnOriginalWithoutCode() throws {
        let m = try validate(["type": "original", "video": NSNull(), "preview": NSNull(),
                              "original": ["base": "aurora", "palette": [[1, 0.2, 0.4], [0.2, 0.2, 0.9], [0, 0, 0.05]]]])
        let original = try #require(m.original?.resolved(id: UUID(), name: m.name))
        #expect(original.slug == "aurora")
        #expect(original.palette[0] == SIMD3<Float>(1, 0.2, 0.4))
        #expect(throws: PackageProblem.unknownOriginal("fireworks")) {
            try validate(["type": "original", "video": NSNull(), "preview": NSNull(), "original": ["base": "fireworks"]])
        }
        #expect(throws: PackageProblem.invalidField("original.palette")) {
            try validate(["type": "original", "video": NSNull(), "preview": NSNull(), "original": ["base": "tide", "palette": [[2, 0, 0]]]])
        }
    }

    @Test func theGalleryOnlyTakesRedistributableWorkWithCredit() throws {
        #expect(throws: PackageProblem.licenseNotRedistributable("LicenseRef-All-Rights-Reserved")) {
            try PackageValidation.galleryLicense(try validate(["license": "LicenseRef-All-Rights-Reserved"]))
        }
        #expect(throws: PackageProblem.attributionRequired) {
            try PackageValidation.galleryLicense(try validate(["attribution": NSNull()]))
        }
        try PackageValidation.galleryLicense(try validate(["license": "CC0-1.0", "attribution": NSNull()]))
    }

    @Test func versionsCompareNumerically() throws {
        #expect(try #require(Version("0.10.0")) > #require(Version("0.9.9")))
        #expect(try #require(Version("1.0")) == #require(Version("1.0.0")))
        #expect(Version("1.x") == nil && Version("") == nil && Version("1.2.3.4.5") == nil)
    }
}

@Suite struct PackageFilesTests {
    let manifest: PackageManifest = {
        var m = PackageManifest(id: "io.github.someone.ocean", name: "Ocean", author: .init(name: "Someone"), license: "CC0-1.0", type: .video)
        m.video = .init(file: "loop.mov")
        m.preview = "preview.jpg"
        return m
    }()

    let good = [PackageFile(name: "wallpaper.json", bytes: 400), PackageFile(name: "loop.mov", bytes: 20_000_000),
                PackageFile(name: "preview.jpg", bytes: 200_000)]

    @Test func acceptsTheNamedFilesAndDocuments() throws {
        try PackageValidation.files(good + [PackageFile(name: "LICENSE", bytes: 2000)], for: manifest)
    }

    @Test func refusesAnythingElse() {
        #expect(throws: PackageProblem.unexpectedFile("install.sh")) {
            try PackageValidation.files(good + [PackageFile(name: "install.sh", bytes: 10)], for: manifest)
        }
        #expect(throws: PackageProblem.unsafeFile("loop.mov")) {
            try PackageValidation.files([good[0], PackageFile(name: "loop.mov", bytes: 10, isSymbolicLink: true), good[2]], for: manifest)
        }
        #expect(throws: PackageProblem.unsafeFile("loop.mov")) {
            try PackageValidation.files([good[0], PackageFile(name: "loop.mov", bytes: 10, isExecutable: true), good[2]], for: manifest)
        }
        #expect(throws: PackageProblem.unsafeFile("Contents")) {
            try PackageValidation.files(good + [PackageFile(name: "Contents", bytes: 0, isRegularFile: false)], for: manifest)
        }
        #expect(throws: PackageProblem.unsafeFile(".hidden")) {
            try PackageValidation.files(good + [PackageFile(name: ".hidden", bytes: 1)], for: manifest)
        }
    }

    @Test func refusesMissingWrongAndOversizedFiles() {
        #expect(throws: PackageProblem.missingFile("loop.mov")) { try PackageValidation.files([good[0], good[2]], for: manifest) }
        var renamed = manifest
        renamed.video = .init(file: "loop.exe")
        #expect(throws: PackageProblem.wrongFileType("loop.exe")) {
            try PackageValidation.files([good[0], PackageFile(name: "loop.exe", bytes: 10), good[2]], for: renamed)
        }
        #expect(throws: PackageProblem.tooLarge("loop.mov")) {
            try PackageValidation.files([good[0], PackageFile(name: "loop.mov", bytes: PackageLimits.videoBytes + 1), good[2]], for: manifest)
        }
        #expect(throws: PackageProblem.tooLarge("LICENSE")) {
            try PackageValidation.files(good + [PackageFile(name: "LICENSE", bytes: PackageLimits.documentBytes + 1)], for: manifest)
        }
    }
}

@Suite struct GalleryCatalogTests {
    func entry(_ changes: (inout GalleryEntry) -> Void = { _ in }) -> GalleryEntry {
        var e = GalleryEntry(id: "io.github.kinora.nasa-earthrise", version: "1.0.0", name: "Earthrise", type: .video, author: "NASA",
                             license: "LicenseRef-Public-Domain", attribution: "NASA",
                             download: URL(string: "https://github.com/Sky-walkerX/kinora-gallery/releases/download/v1/earthrise.zip")!,
                             sha256: String(repeating: "a", count: 64), bytes: 30_000_000)
        changes(&e)
        return e
    }

    func catalog(_ entries: [GalleryEntry], schema: Int = 1) throws -> Data {
        var json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(GalleryCatalog(entries: entries))) as! [String: Any]
        json["schemaVersion"] = schema
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test func keepsValidEntriesAndSkipsTheRest() throws {
        let entries = [
            entry(),
            entry { $0.id = "io.github.x.http"; $0.download = URL(string: "http://github.com/x.zip")! },
            entry { $0.id = "io.github.x.elsewhere"; $0.download = URL(string: "https://example.com/x.zip")! },
            entry { $0.id = "io.github.x.license"; $0.license = "LicenseRef-Proprietary" },
            entry { $0.id = "io.github.x.credit"; $0.license = "CC-BY-4.0"; $0.attribution = nil },
            entry { $0.id = "io.github.x.hash"; $0.sha256 = "nothex" },
            entry { $0.id = "io.github.x.huge"; $0.bytes = PackageLimits.totalBytes + 1 },
            entry(),
        ]
        let (decoded, skipped) = try GalleryValidation.decode(try catalog(entries))
        #expect(decoded.entries.map(\.id) == ["io.github.kinora.nasa-earthrise"])
        #expect(skipped == 7)
    }

    @Test func refusesNewerOrBrokenCatalogs() throws {
        #expect(throws: GalleryValidation.Problem.newerSchema(2)) { try GalleryValidation.decode(try catalog([entry()], schema: 2)) }
        #expect(throws: GalleryValidation.Problem.unreadable) { try GalleryValidation.decode(Data("{}".utf8)) }
        #expect(throws: GalleryValidation.Problem.tooLarge) { try GalleryValidation.decode(Data(count: GalleryValidation.catalogBytes + 1)) }
        let empty = try GalleryValidation.decode(Data(#"{"schemaVersion": 1, "entries": []}"#.utf8))
        #expect(empty.catalog.entries.isEmpty)
    }

    @Test func onlyFetchesFromGitHubOverHTTPS() {
        #expect(GalleryValidation.isAllowed(GalleryCatalog.defaultURL))
        #expect(GalleryValidation.isAllowed(URL(string: "https://objects.githubusercontent.com/x")!))
        #expect(!GalleryValidation.isAllowed(URL(string: "https://github.com.evil.example/x")!))
        #expect(!GalleryValidation.isAllowed(URL(string: "https://user:pw@github.com/x")!))
        #expect(!GalleryValidation.isAllowed(URL(string: "https://github.com:8443/x")!))
        #expect(!GalleryValidation.isAllowed(URL(string: "ftp://github.com/x")!))
    }

    @Test func spotsUltrawideEntries() {
        #expect(entry { $0.width = 5120; $0.height = 1440 }.isUltrawide)
        #expect(!entry { $0.width = 3840; $0.height = 2160 }.isUltrawide)
    }
}

@Suite struct PackageArchiveTests {
    @Test func readsZipinfoTotals() {
        #expect(PackageArchive.zipTotals("Archive:  x.zip\nZip file size: 1 bytes\n3 files, 20512 bytes uncompressed, 20000 bytes compressed:  2.5%\n")
                == PackageArchive.Totals(files: 3, bytes: 20512))
        #expect(PackageArchive.zipTotals("1 file, 9 bytes uncompressed, 9 bytes compressed:  0.0%") == PackageArchive.Totals(files: 1, bytes: 9))
        #expect(PackageArchive.zipTotals("Empty zipfile.") == nil)
        #expect(PackageArchive.zipTotals("x files, y bytes uncompressed") == nil)
    }
}
