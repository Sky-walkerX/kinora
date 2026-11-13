// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

/// The examples and the staged gallery catalog in the repository must pass Kinora's own checks.
@Suite struct ExamplePackageTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theExamplePackageIsValid() throws {
        let folder = Self.root.appendingPathComponent("examples/aurora-rose")
        let manifest = try PackageValidation.manifest(try Data(contentsOf: folder.appendingPathComponent("wallpaper.json")), kinoraVersion: "0.1.0")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let files = try names.map { name -> PackageFile in
            let size = (try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value ?? 0
            return PackageFile(name: name, bytes: size)
        }
        try PackageValidation.files(files, for: manifest)
        try PackageValidation.galleryLicense(manifest)
        #expect(manifest.original?.resolved(id: UUID(), name: manifest.name) != nil)
    }

    @Test func theStagedGalleryCatalogIsValid() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("gallery/catalog.json"))
        let (catalog, skipped) = try GalleryValidation.decode(data)
        #expect(skipped == 0)
        #expect(catalog.schemaVersion == GalleryCatalog.currentSchemaVersion)
    }
}
