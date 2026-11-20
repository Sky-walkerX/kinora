// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Compression
import Foundation
import KinoraKit
import Testing
@testable import KinoraMedia

/// Builds zip archives byte by byte, including ones no honest tool would make.
struct ZipWriter {
    struct File {
        var path: String
        var data: Data
        var deflate = false
        /// Unix mode; 0o100644 is a plain file, 0o120777 a link.
        var mode: UInt32 = 0o100644
        /// Overrides for lying archives.
        var declaredSize: UInt32?
        var declaredCRC: UInt32?
    }

    var files: [File] = []

    mutating func add(_ path: String, _ text: String, deflate: Bool = false, mode: UInt32 = 0o100644) {
        files.append(File(path: path, data: Data(text.utf8), deflate: deflate, mode: mode))
    }

    func data() throws -> Data {
        var out = Data(), directory = Data()
        for file in files {
            var crc = CRC32()
            crc.update(file.data)
            let stored = file.deflate ? try Self.deflate(file.data) : file.data
            let name = Data(file.path.utf8)
            let offset = UInt32(out.count)
            let size = file.declaredSize ?? UInt32(file.data.count)
            let checksum = file.declaredCRC ?? crc.value
            let method: UInt16 = file.deflate ? 8 : 0
            // Local header.
            out.append(le32: 0x0403_4B50); out.append(le16: 20); out.append(le16: 0x0800); out.append(le16: method)
            out.append(le16: 0); out.append(le16: 0); out.append(le32: checksum)
            out.append(le32: UInt32(stored.count)); out.append(le32: size)
            out.append(le16: UInt16(name.count)); out.append(le16: 0)
            out.append(name); out.append(stored)
            // Central directory entry, made on Unix (3) so the mode is kept.
            directory.append(le32: 0x0201_4B50); directory.append(le16: 3 << 8 | 20); directory.append(le16: 20)
            directory.append(le16: 0x0800); directory.append(le16: method); directory.append(le16: 0); directory.append(le16: 0)
            directory.append(le32: checksum); directory.append(le32: UInt32(stored.count)); directory.append(le32: size)
            directory.append(le16: UInt16(name.count)); directory.append(le16: 0); directory.append(le16: 0)
            directory.append(le16: 0); directory.append(le16: 0); directory.append(le32: file.mode << 16); directory.append(le32: offset)
            directory.append(name)
        }
        let directoryOffset = UInt32(out.count)
        out.append(directory)
        out.append(le32: 0x0605_4B50); out.append(le16: 0); out.append(le16: 0)
        out.append(le16: UInt16(files.count)); out.append(le16: UInt16(files.count))
        out.append(le32: UInt32(directory.count)); out.append(le32: directoryOffset); out.append(le16: 0)
        return out
    }

    func write(to url: URL) throws { try data().write(to: url) }

    /// Raw DEFLATE, as zip stores it.
    static func deflate(_ data: Data) throws -> Data {
        var out = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in if let chunk { out.append(chunk) } }
        try filter.write(data)
        try filter.finalize()
        return out
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func append(le32 value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }
}

@Suite struct ZipArchiveTests {
    func archive(_ build: (inout ZipWriter) -> Void) throws -> (ZipArchive, URL) {
        let folder = try temporaryFolder()
        var writer = ZipWriter()
        build(&writer)
        let url = folder.appendingPathComponent("test.zip")
        try writer.write(to: url)
        return (try ZipArchive(url: url), folder)
    }

    @Test func readsStoredAndDeflatedEntries() throws {
        let text = String(repeating: "living wallpaper ", count: 400)
        let (zip, folder) = try archive { $0.add("a.txt", "hello"); $0.add("dir/b.txt", text, deflate: true) }
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(zip.entries.map(\.path) == ["a.txt", "dir/b.txt"])
        #expect(try zip.data(#require(zip.entry("a.txt")), limit: 100) == Data("hello".utf8))
        let entry = try #require(zip.entry("dir/b.txt"))
        #expect(entry.method == 8 && entry.compressedSize < entry.size)
        let out = folder.appendingPathComponent("out.txt")
        try zip.extract(entry, to: out, limit: 1_000_000)
        #expect(try Data(contentsOf: out) == Data(text.utf8))
    }

    @Test func matchesNamesHoweverTheirUnicodeIsComposed() throws {
        let (zip, folder) = try archive { $0.add("Cafe\u{301}.txt", "x") }
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(zip.entry("Café.txt") != nil)
    }

    @Test func refusesEntriesLargerThanAllowed() throws {
        let (zip, folder) = try archive { $0.add("big.txt", String(repeating: "x", count: 5000)) }
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ZipArchive.Failure.tooLarge("big.txt")) { try zip.data(#require(zip.entry("big.txt")), limit: 4999) }
    }

    @Test func stopsABombAtItsDeclaredSize() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var writer = ZipWriter()
        // Declares 100 bytes; inflates to a megabyte.
        writer.files.append(.init(path: "bomb.bin", data: Data(count: 1_000_000), deflate: true, declaredSize: 100))
        let url = folder.appendingPathComponent("bomb.zip")
        try writer.write(to: url)
        let zip = try ZipArchive(url: url)
        let entry = try #require(zip.entry("bomb.bin"))
        let out = folder.appendingPathComponent("out")
        #expect(throws: ZipArchive.Failure.damaged("an entry is larger than it says")) { try zip.extract(entry, to: out, limit: 1_000_000) }
        #expect(!FileManager.default.fileExists(atPath: out.path), "nothing half-written is left")
    }

    @Test func checksEveryByteAgainstTheCRC() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var writer = ZipWriter()
        writer.files.append(.init(path: "x.txt", data: Data("tampered".utf8), declaredCRC: 0xDEAD_BEEF))
        let url = folder.appendingPathComponent("crc.zip")
        try writer.write(to: url)
        let zip = try ZipArchive(url: url)
        #expect(throws: ZipArchive.Failure.damaged("an entry fails its checksum")) { try zip.data(#require(zip.entry("x.txt")), limit: 100) }
    }

    @Test func recognisesLinksAndNeverReadsThem() throws {
        let (zip, folder) = try archive { $0.add("link", "/etc/passwd", mode: 0o120777); $0.add("tool", "#!/bin/sh", mode: 0o100755) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = try #require(zip.entry("link"))
        #expect(link.isSymbolicLink && link.isSpecial)
        #expect(throws: ZipArchive.Failure.unsupported("links and special files")) { try zip.data(link, limit: 100) }
        #expect(try #require(zip.entry("tool")).isExecutable)
    }

    @Test func refusesWhatIsNotAZip() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("no.zip")
        try Data("PK this is not really a zip at all, just text pretending".utf8).write(to: url)
        #expect(throws: ZipArchive.Failure.notAZip) { try ZipArchive(url: url) }
        // A real archive cut short.
        var writer = ZipWriter()
        writer.add("a.txt", String(repeating: "a", count: 2000))
        let whole = try writer.data()
        try whole.prefix(whole.count - 30).write(to: url)
        #expect(throws: (any Error).self) { try ZipArchive(url: url) }
    }

    @Test func limitsTheNumberOfEntries() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var writer = ZipWriter()
        for index in 0..<10 { writer.add("f\(index).txt", "x") }
        let url = folder.appendingPathComponent("many.zip")
        try writer.write(to: url)
        #expect(throws: ZipArchive.Failure.tooManyEntries) { try ZipArchive(url: url, maxEntries: 9) }
        #expect(try ZipArchive(url: url, maxEntries: 10).entries.count == 10)
    }

    @Test func judgesPathsStrictly() {
        for good in ["a.mov", "folder/a.mov", "folder/", "a b/c d.json", "Café.png"] { #expect(ZipArchive.isSafePath(good), "\(good)") }
        for bad in ["", "/etc/passwd", "../x", "a/../../x", "a//b", "./a", "a\\b", "..\\..\\x", "a\u{0}b", "a\nb"] {
            #expect(!ZipArchive.isSafePath(bad), "\(bad)")
        }
    }
}

@Suite struct PackageSourceTests {
    let manifest = #"{"format":"kinora-wallpaper","formatVersion":1}"#

    func zip(_ build: (inout ZipWriter) -> Void) throws -> (URL, URL) {
        let folder = try temporaryFolder()
        var writer = ZipWriter()
        build(&writer)
        let url = folder.appendingPathComponent("p.kinorawallpaper")
        try writer.write(to: url)
        let work = folder.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (url, work)
    }

    func open(_ url: URL, _ work: URL, depth: Int = 2) throws -> PackageSource {
        try PackageSource.open(url, work: work, manifests: [PackageManifest.fileName], maxEntries: 64, maxDepth: depth)
    }

    @Test func findsTheManifestAtTheTopOrInTheOnlyFolder() throws {
        let (top, work) = try zip { $0.add("wallpaper.json", manifest); $0.add("loop.mov", "v") }
        #expect(try open(top, work).read("wallpaper.json", limit: 1000) == Data(manifest.utf8))
        let (nested, work2) = try zip { $0.add("Ocean/wallpaper.json", manifest); $0.add("Ocean/loop.mov", "v"); $0.add("__MACOSX/Ocean/._loop.mov", "junk") }
        let source = try open(nested, work2)
        #expect(source.contains("loop.mov"))
        #expect(try source.listing().map(\.name) == ["loop.mov", "wallpaper.json"])
    }

    @Test func extractsOnlyWhatIsAskedForUnderItsOwnName() throws {
        let (url, work) = try zip { $0.add("wallpaper.json", manifest); $0.add("loop.mov", "video bytes"); $0.add("extra.txt", "never written") }
        let file = try open(url, work).file("loop.mov", work: work, limit: 100)
        #expect(file.deletingLastPathComponent().standardizedFileURL.path == work.standardizedFileURL.path)
        #expect(file.lastPathComponent != "loop.mov" && file.pathExtension == "mov")
        #expect(try Data(contentsOf: file) == Data("video bytes".utf8))
        let written = try FileManager.default.contentsOfDirectory(atPath: work.path).sorted()
        #expect(written.count == 2, "only the copy of the archive and the one file asked for: \(written)")
    }

    @Test func refusesLinksTraversalAndDeepNesting() throws {
        let (link, w1) = try zip { $0.add("wallpaper.json", manifest); $0.add("loop.mov", "/Users", mode: 0o120755) }
        #expect(throws: PackageSource.Failure.unsafe("loop.mov")) { try open(link, w1) }
        let (climb, w2) = try zip { $0.add("wallpaper.json", manifest); $0.add("../../Library/LaunchAgents/x.plist", "x") }
        #expect(throws: PackageSource.Failure.unsafe("../../Library/LaunchAgents/x.plist")) { try open(climb, w2) }
        let (deep, w3) = try zip { $0.add("wallpaper.json", manifest); $0.add("a/b/c.mov", "x") }
        #expect(throws: PackageSource.Failure.unsafe("a/b/c.mov")) { try open(deep, w3) }
        let (absolute, w4) = try zip { $0.add("wallpaper.json", manifest); $0.add("/tmp/x", "x") }
        #expect(throws: PackageSource.Failure.unsafe("/tmp/x")) { try open(absolute, w4) }
    }

    @Test func showsNestedFilesAsFoldersSoValidationRefusesThem() throws {
        let (url, work) = try zip { $0.add("wallpaper.json", manifest); $0.add("media/loop.mov", "x") }
        let listing = try open(url, work).listing()
        let media = try #require(listing.first { $0.name == "media" })
        #expect(!media.isRegularFile)
    }

    @Test func refusesAnArchiveDeclaringMoreThanTheLimit() throws {
        let folder = try temporaryFolder()
        var writer = ZipWriter()
        writer.add("wallpaper.json", manifest)
        writer.files.append(.init(path: "loop.mov", data: Data("x".utf8), declaredSize: UInt32.max - 1))
        let url = folder.appendingPathComponent("huge.zip")
        try writer.write(to: url)
        #expect(throws: PackageSource.Failure.tooLarge) { try open(url, folder) }
    }

    @Test func foldersAreReadInPlaceButOnlyInside() throws {
        let folder = try temporaryFolder()
        let package = folder.appendingPathComponent("Pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: package.appendingPathComponent("wallpaper.json"))
        try Data("v".utf8).write(to: package.appendingPathComponent("loop.mov"))
        try Data("secret".utf8).write(to: folder.appendingPathComponent("secret.mov"))
        try FileManager.default.createSymbolicLink(atPath: package.appendingPathComponent("escape.mov").path, withDestinationPath: "../secret.mov")
        let source = try open(package, folder)
        #expect(try source.file("loop.mov", work: folder, limit: 10).lastPathComponent == "loop.mov")
        #expect(throws: PackageSource.Failure.unsafe("escape.mov")) { try source.file("escape.mov", work: folder, limit: 10) }
        // A manifest that is a link to something huge or endless is never read through.
        let other = folder.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: other.appendingPathComponent("wallpaper.json").path, withDestinationPath: "/dev/zero")
        #expect(throws: (any Error).self) { try open(other, folder).read("wallpaper.json", limit: 1000) }
    }
}
