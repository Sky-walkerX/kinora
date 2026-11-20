// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Compression
import Foundation

/// A zip archive read by Kinora itself, for packages and imported wallpapers, which are
/// untrusted. Nothing is extracted until asked for, entry by entry: Kinora decides what each
/// extracted file is called and where it goes, inflates no more than the entry declares and the
/// caller allows, and checks every byte against the entry's CRC. Links, encryption, multi-disk
/// and zip64 archives are refused. Only stored and deflated entries are read.
///
/// This replaces running `zipinfo` and `ditto` on the file: those measured and extracted by
/// rules Kinora couldn't see (and `zipinfo` reads its argument as a pattern), and `ditto`
/// wrote every entry before anything was checked.
public final class ZipArchive: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        /// The entry's path inside the archive, as stored.
        public let path: String
        public let compressedSize: Int64
        /// What the entry inflates to, as declared. Extraction stops at this many bytes.
        public let size: Int64
        public let method: UInt16
        public let flags: UInt16
        public let crc32: UInt32
        let localHeaderOffset: Int64
        /// The Unix file mode, when the archive was made on a Unix-like system.
        public let mode: UInt32?

        public var isDirectory: Bool { path.hasSuffix("/") || mode.map { $0 & 0o170000 == 0o040000 } == true }
        public var isSymbolicLink: Bool { mode.map { $0 & 0o170000 == 0o120000 } == true }
        /// Anything other than a plain file or folder: a link, a device, a pipe.
        public var isSpecial: Bool {
            guard let type = mode.map({ $0 & 0o170000 }), type != 0 else { return false }
            return type != 0o100000 && type != 0o040000
        }
        public var isExecutable: Bool { !isDirectory && mode.map { $0 & 0o111 != 0 } == true }
        public var isEncrypted: Bool { flags & 0x1 != 0 }
        /// The path's parts, without a trailing slash.
        public var components: [String] { path.split(separator: "/", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty } }
        /// Finder's and macOS's bookkeeping, which Kinora ignores: `__MACOSX/`, `.DS_Store`, `._name`.
        public var isMetadata: Bool {
            let parts = components
            return parts.first == "__MACOSX" || parts.last == ".DS_Store" || (parts.last?.hasPrefix("._") ?? false)
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case notAZip
        case unsupported(String)
        case damaged(String)
        case tooManyEntries
        case tooLarge(String)
        case cancelled
    }

    public let entries: [Entry]
    private let handle: FileHandle
    private let fileSize: Int64
    private let lock = NSLock()

    /// Reads the archive's directory. Nothing is extracted.
    public init(url: URL, maxEntries: Int = 4096) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.notAZip }
        self.handle = handle
        let end = (try? handle.seekToEnd()).map(Int64.init) ?? 0
        fileSize = end
        guard end >= 22 else { throw Failure.notAZip }

        // The end-of-central-directory record: within the last 22 + 65535 bytes.
        let tailLength = Int(min(end, 22 + 65_535))
        let tail = try Self.read(handle, at: end - Int64(tailLength), count: tailLength)
        guard let eocd = Self.lastSignature(0x0605_4B50, in: tail, minimumRemaining: 22) else { throw Failure.notAZip }
        if eocd >= 20, tail.uint32(at: eocd - 20) == 0x0706_4B50 { throw Failure.unsupported("zip64 archives") }
        let disk = tail.uint16(at: eocd + 4), directoryDisk = tail.uint16(at: eocd + 6)
        let countHere = Int(tail.uint16(at: eocd + 8)), count = Int(tail.uint16(at: eocd + 10))
        let directorySize = Int64(tail.uint32(at: eocd + 12)), directoryOffset = Int64(tail.uint32(at: eocd + 16))
        guard disk == 0, directoryDisk == 0, countHere == count else { throw Failure.unsupported("archives split across disks") }
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else { throw Failure.unsupported("zip64 archives") }
        guard count <= maxEntries else { throw Failure.tooManyEntries }
        guard directoryOffset >= 0, directorySize >= 0, directoryOffset + directorySize <= end, directorySize <= 64 * 1024 * 1024 else {
            throw Failure.damaged("its directory is out of bounds")
        }

        let directory = try Self.read(handle, at: directoryOffset, count: Int(directorySize))
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var at = 0
        for _ in 0..<count {
            guard at + 46 <= directory.count, directory.uint32(at: at) == 0x0201_4B50 else { throw Failure.damaged("its directory is cut short") }
            let madeBy = directory.uint16(at: at + 4)
            let flags = directory.uint16(at: at + 8), method = directory.uint16(at: at + 10)
            let crc = directory.uint32(at: at + 16)
            let compressed = Int64(directory.uint32(at: at + 20)), size = Int64(directory.uint32(at: at + 24))
            let nameLength = Int(directory.uint16(at: at + 28)), extraLength = Int(directory.uint16(at: at + 30))
            let commentLength = Int(directory.uint16(at: at + 32))
            let external = directory.uint32(at: at + 38), offset = Int64(directory.uint32(at: at + 42))
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else { throw Failure.unsupported("zip64 archives") }
            let nameStart = at + 46
            guard nameStart + nameLength + extraLength + commentLength <= directory.count else { throw Failure.damaged("an entry runs past its directory") }
            guard let path = String(data: directory.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8), !path.isEmpty else {
                throw Failure.damaged("an entry's name isn't readable")
            }
            // Unix (3) and macOS (19) archivers keep the file mode in the top half.
            let system = madeBy >> 8
            let mode: UInt32? = (system == 3 || system == 19) && external >> 16 != 0 ? external >> 16 : nil
            entries.append(Entry(path: path, compressedSize: compressed, size: size, method: method, flags: flags, crc32: crc,
                                 localHeaderOffset: offset, mode: mode))
            at = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    deinit { try? handle.close() }

    /// A path Kinora is willing to look at: relative, made of plain names, no `..`, no
    /// backslashes, no control characters. Kinora never writes entries under their own names,
    /// but a path like this is refused rather than interpreted.
    public static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // A folder entry ends in "/", leaving one empty part at the end.
        let named = path.hasSuffix("/") ? parts.dropLast() : parts[...]
        return !named.isEmpty && named.allSatisfy { part in
            let name = String(part)
            return !name.isEmpty && name != "." && name != ".." && !name.contains("\0")
        }
    }

    /// The entry at `path`, matching however its Unicode is composed (Finder and Windows differ).
    public func entry(_ path: String) -> Entry? {
        let wanted = path.precomposedStringWithCanonicalMapping
        return entries.first { $0.path.precomposedStringWithCanonicalMapping == wanted }
    }

    /// The entry's bytes in memory, for small files such as manifests.
    public func data(_ entry: Entry, limit: Int) throws -> Data {
        var data = Data()
        try inflate(entry, limit: Int64(limit), isCancelled: { false }) { data.append($0) }
        return data
    }

    /// Writes the entry to `destination`, which must not exist yet. Removes what it wrote on any failure.
    public func extract(_ entry: Entry, to destination: URL, limit: Int64, isCancelled: () -> Bool = { false }) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o644]),
              let output = try? FileHandle(forWritingTo: destination) else { throw Failure.damaged("Kinora couldn't write its copy") }
        do {
            try inflate(entry, limit: limit, isCancelled: isCancelled) { try output.write(contentsOf: $0) }
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Streams an entry's bytes to `sink`, checking the declared size, the caller's limit and the CRC.
    private func inflate(_ entry: Entry, limit: Int64, isCancelled: () -> Bool, sink: (Data) throws -> Void) throws {
        // The decompressor holds on to its output handler, though never beyond this call.
        try withoutActuallyEscaping(sink) { sink in try inflate(entry, limit: limit, isCancelled: isCancelled, escapingSink: sink) }
    }

    private func inflate(_ entry: Entry, limit: Int64, isCancelled: () -> Bool, escapingSink sink: @escaping (Data) throws -> Void) throws {
        guard !entry.isEncrypted else { throw Failure.unsupported("encrypted files") }
        guard !entry.isDirectory, !entry.isSpecial else { throw Failure.unsupported("links and special files") }
        guard entry.size <= limit else { throw Failure.tooLarge(entry.path) }
        guard entry.method == 0 || entry.method == 8 else { throw Failure.unsupported("compression method \(entry.method)") }
        lock.lock()
        defer { lock.unlock() }
        // The local header repeats the name and may carry different extra data; only its lengths matter.
        let header = try Self.read(handle, at: entry.localHeaderOffset, count: 30)
        guard header.uint32(at: 0) == 0x0403_4B50 else { throw Failure.damaged("an entry's header is missing") }
        let dataStart = entry.localHeaderOffset + 30 + Int64(header.uint16(at: 26)) + Int64(header.uint16(at: 28))
        guard dataStart + entry.compressedSize <= fileSize else { throw Failure.damaged("an entry runs past the end of the file") }
        if entry.method == 0, entry.compressedSize != entry.size { throw Failure.damaged("a stored entry's sizes disagree") }

        var crc = CRC32()
        var written: Int64 = 0
        func accept(_ chunk: Data) throws {
            written += Int64(chunk.count)
            // Never more than the entry declared: a bomb's real size shows here, not in its directory.
            guard written <= entry.size else { throw Failure.damaged("an entry is larger than it says") }
            crc.update(chunk)
            try sink(chunk)
        }
        var filter: OutputFilter?
        if entry.method == 8 {
            // Compression's zlib is raw DEFLATE, which is what zip stores.
            filter = try OutputFilter(.decompress, using: .zlib, bufferCapacity: 256 * 1024) { chunk in
                if let chunk { try accept(chunk) }
            }
        }
        try handle.seek(toOffset: UInt64(dataStart))
        var remaining = entry.compressedSize
        while remaining > 0 {
            if isCancelled() { throw Failure.cancelled }
            let count = Int(min(remaining, 1024 * 1024))
            guard let chunk = try handle.read(upToCount: count), chunk.count == count else { throw Failure.damaged("the file ends early") }
            remaining -= Int64(count)
            if let filter { try filter.write(chunk) } else { try accept(chunk) }
        }
        do { try filter?.finalize() } catch let failure as Failure { throw failure } catch { throw Failure.damaged("an entry can't be inflated") }
        guard written == entry.size else { throw Failure.damaged("an entry is smaller than it says") }
        guard crc.value == entry.crc32 else { throw Failure.damaged("an entry fails its checksum") }
    }

    // MARK: - Bytes

    private static func read(_ handle: FileHandle, at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else { throw Failure.damaged("an offset is out of bounds") }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: count), data.count == count else { throw Failure.damaged("the file ends early") }
        return data
    }

    /// The last place `signature` occurs with at least `minimumRemaining` bytes from it to the end.
    private static func lastSignature(_ signature: UInt32, in data: Data, minimumRemaining: Int) -> Int? {
        var at = data.count - minimumRemaining
        while at >= 0 {
            if data.uint32(at: at) == signature { return at }
            at -= 1
        }
        return nil
    }
}

/// The CRC-32 zip uses (IEEE 802.3, reflected).
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        var c = state
        Self.table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { bytes in
                for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
            }
        }
        state = c
    }

    var value: UInt32 { state ^ 0xFFFF_FFFF }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }
}
