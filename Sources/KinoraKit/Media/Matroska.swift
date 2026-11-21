// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

// A small reader for Matroska and WebM, the containers Lively and Wallpaper Engine videos often
// come in and AVFoundation cannot open. It finds the first video track and hands out its frames
// with their timestamps; Kinora decodes them with VideoToolbox and converts them to HEVC once,
// at import. Audio, subtitles, chapters and tags are skipped: wallpapers are silent.
//
// Files are untrusted. The reader reads on demand rather than loading the file, checks every
// size against its parent and the file, and caps what it holds in memory at once.

/// Bytes to parse, read on demand.
public protocol MatroskaByteSource {
    var count: UInt64 { get }
    /// Up to `length` bytes at `offset`; fewer only at the end of the source.
    func read(at offset: UInt64, length: Int) throws -> Data
}

/// Bytes already in memory, for tests and small files.
public struct MatroskaDataSource: MatroskaByteSource {
    public let data: Data
    public init(_ data: Data) { self.data = data }
    public var count: UInt64 { UInt64(data.count) }
    public func read(at offset: UInt64, length: Int) throws -> Data {
        guard offset < count, length > 0 else { return Data() }
        let start = data.startIndex + Int(offset)
        return data.subdata(in: start..<min(data.endIndex, start + length))
    }
}

/// A file, read with positioned reads.
public final class MatroskaFileSource: MatroskaByteSource {
    private let handle: FileHandle
    public let count: UInt64

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        count = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    public func read(at offset: UInt64, length: Int) throws -> Data {
        guard offset < count, length > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }
}

public enum MatroskaError: Error, Equatable, Sendable {
    /// Not EBML, or EBML of a kind other than Matroska or WebM.
    case notMatroska
    /// The structure does not parse. The detail is for logs, not for people.
    case damaged(String)
    /// No video track.
    case noVideo
    /// The frames are encrypted, or compressed in a way Kinora does not undo.
    case protected
    /// An element or frame beyond Kinora's limits.
    case tooLarge
}

public enum MatroskaLimits {
    /// The EBML header, Info and Tracks are read whole; real ones are a few hundred bytes.
    public static let headerBytes = 1 << 20
    /// One frame, or one block group. A 4K keyframe is a few megabytes.
    public static let frameBytes = 64 << 20
    /// Codec private data: avcC, hvcC and av1C records are tiny.
    public static let codecPrivateBytes = 1 << 16
    public static let maxTracks = 128
    /// The widest or tallest picture Kinora converts.
    public static let maxSide = 8192
}

/// The video track a file holds, as its header describes it.
public struct MatroskaVideoTrack: Equatable, Sendable {
    public var number: UInt64
    public var codecID: String
    public var codecPrivate: Data?
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The shape to show, when it differs from the stored pixels; nil when the file doesn't say.
    public var displayWidth: Int?
    public var displayHeight: Int?
    /// Nanoseconds per frame, when the file says.
    public var defaultDuration: UInt64?
    /// Bytes to put back in front of every frame ("header stripping"), usually none.
    public var strippedHeader: Data?
    public var colour: Colour?

    /// ISO/IEC 23091-2 code points, as in the Colour element; nil where the file doesn't say.
    public struct Colour: Equatable, Sendable {
        public var matrixCoefficients: Int?
        public var bitsPerChannel: Int?
        public var chromaSubsamplingHorizontal: Int?
        public var chromaSubsamplingVertical: Int?
        /// 1 broadcast range, 2 full range.
        public var range: Int?
        public var transferCharacteristics: Int?
        public var primaries: Int?

        public init() {}
    }

    /// The picture's shape as it is meant to be shown, in pixels.
    public var shownSize: (width: Int, height: Int) {
        if let displayWidth, let displayHeight, displayWidth > 0, displayHeight > 0 {
            // Display sizes describe the shape; keep the stored width and adjust the height.
            let height = Double(pixelWidth) * Double(displayHeight) / Double(displayWidth)
            return (pixelWidth, max(1, Int(height.rounded())))
        }
        return (pixelWidth, pixelHeight)
    }
}

/// One frame of the video track.
public struct MatroskaFrame: Equatable, Sendable {
    /// Presentation time in nanoseconds from the segment's start. Can be negative.
    public var time: Int64
    /// Nanoseconds, when the block says.
    public var duration: Int64?
    public var isKey: Bool
    /// Decode but don't show.
    public var isInvisible: Bool
    public var data: Data
}

/// Reads a Matroska or WebM file's header, then its video frames in file order.
public final class MatroskaReader {
    public let docType: String
    /// Nanoseconds per timestamp tick.
    public let timestampScale: UInt64
    /// In nanoseconds, when the file says.
    public let duration: Double?
    public let video: MatroskaVideoTrack

    private let source: any MatroskaByteSource
    private let segmentEnd: UInt64
    private var position: UInt64
    private var clusterEnd: UInt64?
    private var clusterIsUnknownSize = false
    private var clusterTimestamp: Int64 = 0
    private var pending: [MatroskaFrame] = []

    /// How far through the file reading has got, 0...1.
    public var progress: Double { source.count == 0 ? 1 : min(1, Double(position) / Double(source.count)) }

    public init(source: any MatroskaByteSource) throws {
        self.source = source
        // EBML header.
        guard let ebml = (try? EBML.header(source, at: 0, end: source.count)) ?? nil, ebml.id == EBML.ID.ebml, let ebmlSize = ebml.size else {
            throw MatroskaError.notMatroska
        }
        guard ebmlSize <= UInt64(MatroskaLimits.headerBytes) else { throw MatroskaError.notMatroska }
        let header = try EBML.children(of: try EBML.body(source, ebml, size: ebmlSize))
        let type = header.first { $0.id == EBML.ID.docType }.map { EBML.string($0.data) } ?? "matroska"
        guard type == "webm" || type == "matroska" else { throw MatroskaError.notMatroska }
        if let maxID = header.first(where: { $0.id == EBML.ID.maxIDLength }).flatMap({ EBML.uint($0.data) }), maxID > 4 {
            throw MatroskaError.damaged("EBMLMaxIDLength \(maxID)")
        }
        if let maxSize = header.first(where: { $0.id == EBML.ID.maxSizeLength }).flatMap({ EBML.uint($0.data) }), maxSize > 8 {
            throw MatroskaError.damaged("EBMLMaxSizeLength \(maxSize)")
        }
        docType = type

        // The first segment, after any Void elements.
        var offset = ebml.dataOffset + ebmlSize
        var segment: EBML.Header?
        while offset < source.count, segment == nil {
            guard let next = try EBML.header(source, at: offset, end: source.count) else { break }
            if next.id == EBML.ID.segment { segment = next; break }
            guard next.id == EBML.ID.void, let size = next.size else { throw MatroskaError.damaged("no segment") }
            offset = next.dataOffset + size
        }
        guard let segment else { throw MatroskaError.damaged("no segment") }
        // A truncated download keeps what it has.
        let end = segment.size.map { min(source.count, segment.dataOffset + $0) } ?? source.count
        segmentEnd = end

        // Info and Tracks, up to the first cluster.
        var scale: UInt64 = 1_000_000
        var length: Double?
        var track: MatroskaVideoTrack?
        var tracksSeen = false
        offset = segment.dataOffset
        while offset < end {
            guard let child = try EBML.header(source, at: offset, end: end) else { break }
            if child.id == EBML.ID.cluster { break }
            guard let size = child.size else { throw MatroskaError.damaged("unknown size \(String(child.id, radix: 16))") }
            switch child.id {
            case EBML.ID.info:
                guard size <= UInt64(MatroskaLimits.headerBytes) else { throw MatroskaError.tooLarge }
                for field in try EBML.children(of: try EBML.body(source, child, size: size)) {
                    if field.id == EBML.ID.timestampScale, let value = EBML.uint(field.data) {
                        guard value > 0, value <= 1_000_000_000 else { throw MatroskaError.damaged("timestamp scale \(value)") }
                        scale = value
                    } else if field.id == EBML.ID.duration, let value = EBML.float(field.data), value.isFinite, value >= 0 {
                        length = value
                    }
                }
            case EBML.ID.tracks:
                guard size <= UInt64(MatroskaLimits.headerBytes) else { throw MatroskaError.tooLarge }
                track = try Self.videoTrack(in: try EBML.body(source, child, size: size))
                tracksSeen = true
            default:
                break
            }
            offset = child.dataOffset + size
        }
        guard tracksSeen else { throw MatroskaError.damaged("no tracks before the first cluster") }
        guard let track else { throw MatroskaError.noVideo }
        timestampScale = scale
        duration = length.map { $0 * Double(scale) }
        video = track
        position = offset
    }

    /// The next frame of the video track, or nil at the end.
    public func nextFrame() throws -> MatroskaFrame? {
        while true {
            if !pending.isEmpty { return pending.removeFirst() }
            if let clusterEnd, position >= clusterEnd { self.clusterEnd = nil }
            guard position < segmentEnd, let element = try EBML.header(source, at: position, end: segmentEnd) else { return nil }
            guard let clusterEnd else {
                // Between clusters: enter the next one, skip anything else. A second segment
                // (a chained file) ends this one.
                if element.id == EBML.ID.segment || element.id == EBML.ID.ebml { return nil }
                if element.id == EBML.ID.cluster {
                    clusterIsUnknownSize = element.size == nil
                    self.clusterEnd = element.size.map { min(segmentEnd, element.dataOffset + $0) } ?? segmentEnd
                    clusterTimestamp = 0
                    position = element.dataOffset
                } else {
                    guard let size = element.size else { throw MatroskaError.damaged("unknown size \(String(element.id, radix: 16))") }
                    position = element.dataOffset + size
                }
                continue
            }
            // An unknown-size cluster ends where the next top-level element starts.
            if clusterIsUnknownSize, EBML.ID.segmentLevel.contains(element.id) {
                self.clusterEnd = nil
                continue
            }
            guard let size = element.size else { throw MatroskaError.damaged("unknown size in a cluster") }
            let next = element.dataOffset + size
            // A cut-off download ends with its last whole frame.
            if next > clusterEnd { return nil }
            switch element.id {
            case EBML.ID.timestamp:
                guard size <= 8, let value = EBML.uint(try EBML.body(source, element, size: size)), value <= UInt64(Int64.max) else {
                    throw MatroskaError.damaged("cluster timestamp")
                }
                clusterTimestamp = Int64(value)
            case EBML.ID.simpleBlock:
                guard size <= UInt64(MatroskaLimits.frameBytes) else { throw MatroskaError.tooLarge }
                pending = try frames(inBlock: try EBML.body(source, element, size: size), simple: true, hasReference: false, duration: nil)
            case EBML.ID.blockGroup:
                guard size <= UInt64(MatroskaLimits.frameBytes) else { throw MatroskaError.tooLarge }
                let children = try EBML.children(of: try EBML.body(source, element, size: size))
                if let block = children.first(where: { $0.id == EBML.ID.block }) {
                    let reference = children.contains { $0.id == EBML.ID.referenceBlock }
                    let ticks = children.first { $0.id == EBML.ID.blockDuration }.flatMap { EBML.uint($0.data) }
                    pending = try frames(inBlock: block.data, simple: false, hasReference: reference, duration: ticks)
                }
            default:
                break
            }
            position = next
        }
    }

    // MARK: - Pieces

    /// The video frames in a SimpleBlock or Block, unlaced. Frames of other tracks give none.
    func frames(inBlock data: Data, simple: Bool, hasReference: Bool, duration ticks: UInt64?) throws -> [MatroskaFrame] {
        let bytes = [UInt8](data)
        guard let (track, trackLength) = EBML.vint(bytes, at: 0, keepMarker: false) else { throw MatroskaError.damaged("block track") }
        guard track.value == video.number else { return [] }
        var p = trackLength
        guard bytes.count >= p + 3 else { throw MatroskaError.damaged("short block") }
        let relative = Int64(Int16(bitPattern: UInt16(bytes[p]) << 8 | UInt16(bytes[p + 1])))
        let flags = bytes[p + 2]
        p += 3
        let sizes = try Self.laceSizes(bytes, from: &p, lacing: (flags >> 1) & 3)
        let (time, overflow) = (clusterTimestamp + relative).multipliedReportingOverflow(by: Int64(timestampScale))
        guard !overflow else { throw MatroskaError.damaged("timestamp overflow") }
        var duration: Int64?
        if let ticks, ticks <= UInt64(Int64.max) / timestampScale { duration = Int64(ticks * timestampScale) }
        let step = video.defaultDuration.flatMap { $0 <= UInt64(Int64.max) ? Int64($0) : nil }
        let isKey = simple ? flags & 0x80 != 0 : !hasReference
        var frames: [MatroskaFrame] = []
        for (index, size) in sizes.enumerated() {
            var frame = Data(bytes[p..<(p + size)])
            if let header = video.strippedHeader { frame = header + frame }
            p += size
            let offset = Int64(index) * (step ?? 0)
            frames.append(MatroskaFrame(time: time &+ offset, duration: sizes.count == 1 ? duration : step, isKey: isKey && index == 0,
                                        isInvisible: flags & 0x08 != 0, data: frame))
        }
        return frames
    }

    /// The sizes of the frames in a block, from its lacing header; one size when not laced.
    static func laceSizes(_ bytes: [UInt8], from p: inout Int, lacing: UInt8) throws -> [Int] {
        if lacing == 0 { return [bytes.count - p] }
        guard p < bytes.count else { throw MatroskaError.damaged("lace count") }
        let count = Int(bytes[p]) + 1
        p += 1
        var sizes: [Int] = []
        switch lacing {
        case 1: // Xiph: each size as a run of 255s and a final smaller byte.
            for _ in 0..<(count - 1) {
                var size = 0
                while true {
                    guard p < bytes.count else { throw MatroskaError.damaged("Xiph lacing") }
                    let byte = Int(bytes[p]); p += 1
                    size += byte
                    if byte < 255 { break }
                }
                sizes.append(size)
            }
        case 3: // EBML: the first size, then signed differences from the previous one.
            guard count > 1 else { break }
            guard let (first, length) = EBML.vint(bytes, at: p, keepMarker: false) else { throw MatroskaError.damaged("EBML lacing") }
            p += length
            var size = Int64(clamping: first.value)
            sizes.append(Int(clamping: size))
            for _ in 0..<max(0, count - 2) {
                guard let (raw, length) = EBML.vint(bytes, at: p, keepMarker: false) else { throw MatroskaError.damaged("EBML lacing") }
                p += length
                let bias = (Int64(1) << (7 * length - 1)) - 1
                size += Int64(clamping: raw.value) - bias
                guard size >= 0 else { throw MatroskaError.damaged("EBML lacing") }
                sizes.append(Int(clamping: size))
            }
        case 2: // Fixed: equal sizes.
            let remaining = bytes.count - p
            guard remaining >= 0, remaining % count == 0 else { throw MatroskaError.damaged("fixed lacing") }
            return Array(repeating: remaining / count, count: count)
        default:
            throw MatroskaError.damaged("lacing")
        }
        let used = sizes.reduce(0, +)
        guard used <= bytes.count - p else { throw MatroskaError.damaged("lace sizes") }
        sizes.append(bytes.count - p - used)
        return sizes
    }

    /// The first enabled video track in a Tracks element's contents.
    static func videoTrack(in data: Data) throws -> MatroskaVideoTrack? {
        let entries = try EBML.children(of: data).filter { $0.id == EBML.ID.trackEntry }
        guard entries.count <= MatroskaLimits.maxTracks else { throw MatroskaError.tooLarge }
        var sawVideo = false
        for entry in entries {
            let fields = try EBML.children(of: entry.data)
            func uint(_ id: UInt32) -> UInt64? { fields.first { $0.id == id }.flatMap { EBML.uint($0.data) } }
            guard uint(EBML.ID.trackType) == 1 else { continue }
            sawVideo = true
            guard uint(EBML.ID.flagEnabled) ?? 1 != 0, let number = uint(EBML.ID.trackNumber), number > 0,
                  let codec = fields.first(where: { $0.id == EBML.ID.codecID }).map({ EBML.string($0.data) }), !codec.isEmpty,
                  let videoElement = fields.first(where: { $0.id == EBML.ID.video })
            else { continue }
            let picture = try EBML.children(of: videoElement.data)
            func dimension(_ id: UInt32) -> Int? {
                picture.first { $0.id == id }.flatMap { EBML.uint($0.data) }.flatMap { $0 > 0 && $0 <= UInt64(Int32.max) ? Int($0) : nil }
            }
            guard let width = dimension(EBML.ID.pixelWidth), let height = dimension(EBML.ID.pixelHeight) else {
                throw MatroskaError.damaged("no picture size")
            }
            guard width <= MatroskaLimits.maxSide, height <= MatroskaLimits.maxSide else { throw MatroskaError.tooLarge }
            var track = MatroskaVideoTrack(number: number, codecID: codec, pixelWidth: width, pixelHeight: height)
            if let privateData = fields.first(where: { $0.id == EBML.ID.codecPrivate })?.data {
                guard privateData.count <= MatroskaLimits.codecPrivateBytes else { throw MatroskaError.tooLarge }
                track.codecPrivate = privateData
            }
            track.defaultDuration = uint(EBML.ID.defaultDuration).flatMap { $0 > 0 ? $0 : nil }
            // Display sizes count only in pixels (unit 0); other units are rare and only about shape too.
            if picture.first(where: { $0.id == EBML.ID.displayUnit }).flatMap({ EBML.uint($0.data) }) ?? 0 <= 3 {
                track.displayWidth = dimension(EBML.ID.displayWidth)
                track.displayHeight = dimension(EBML.ID.displayHeight)
            }
            if let colourElement = picture.first(where: { $0.id == EBML.ID.colour }) {
                let colour = try EBML.children(of: colourElement.data)
                func value(_ id: UInt32) -> Int? { colour.first { $0.id == id }.flatMap { EBML.uint($0.data) }.map { Int(clamping: $0) } }
                var c = MatroskaVideoTrack.Colour()
                c.matrixCoefficients = value(EBML.ID.matrixCoefficients)
                c.bitsPerChannel = value(EBML.ID.bitsPerChannel)
                c.chromaSubsamplingHorizontal = value(EBML.ID.chromaSubsamplingHorz)
                c.chromaSubsamplingVertical = value(EBML.ID.chromaSubsamplingVert)
                c.range = value(EBML.ID.range)
                c.transferCharacteristics = value(EBML.ID.transferCharacteristics)
                c.primaries = value(EBML.ID.primaries)
                track.colour = c
            }
            if let encodings = fields.first(where: { $0.id == EBML.ID.contentEncodings }) {
                track.strippedHeader = try strippedHeader(encodings.data)
            }
            return track
        }
        if sawVideo { throw MatroskaError.damaged("no usable video track") }
        return nil
    }

    /// Header stripping is undone by putting the bytes back; encryption and real compression are refused.
    static func strippedHeader(_ data: Data) throws -> Data? {
        var stripped = Data()
        for encoding in try EBML.children(of: data) where encoding.id == EBML.ID.contentEncoding {
            let fields = try EBML.children(of: encoding.data)
            let type = fields.first { $0.id == EBML.ID.contentEncodingType }.flatMap { EBML.uint($0.data) } ?? 0
            let scope = fields.first { $0.id == EBML.ID.contentEncodingScope }.flatMap { EBML.uint($0.data) } ?? 1
            guard type == 0, let compression = fields.first(where: { $0.id == EBML.ID.contentCompression }) else { throw MatroskaError.protected }
            let settings = try EBML.children(of: compression.data)
            let algorithm = settings.first { $0.id == EBML.ID.contentCompAlgo }.flatMap { EBML.uint($0.data) } ?? 0
            guard algorithm == 3 else { throw MatroskaError.protected }
            if scope & 1 != 0 { stripped += settings.first { $0.id == EBML.ID.contentCompSettings }?.data ?? Data() }
        }
        return stripped.isEmpty ? nil : stripped
    }
}

/// EBML, the binary format under Matroska: elements of an ID, a size and data, each written as a
/// variable-length integer whose first byte says how long it is.
enum EBML {
    enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let docType: UInt32 = 0x4282
        static let maxIDLength: UInt32 = 0x42F2
        static let maxSizeLength: UInt32 = 0x42F3
        static let segment: UInt32 = 0x1853_8067
        static let seekHead: UInt32 = 0x114D_9B74
        static let info: UInt32 = 0x1549_A966
        static let timestampScale: UInt32 = 0x2A_D7B1
        static let duration: UInt32 = 0x4489
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let flagEnabled: UInt32 = 0xB9
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let defaultDuration: UInt32 = 0x23_E383
        static let video: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let displayWidth: UInt32 = 0x54B0
        static let displayHeight: UInt32 = 0x54BA
        static let displayUnit: UInt32 = 0x54B2
        static let colour: UInt32 = 0x55B0
        static let matrixCoefficients: UInt32 = 0x55B1
        static let bitsPerChannel: UInt32 = 0x55B2
        static let chromaSubsamplingHorz: UInt32 = 0x55B3
        static let chromaSubsamplingVert: UInt32 = 0x55B4
        static let range: UInt32 = 0x55B9
        static let transferCharacteristics: UInt32 = 0x55BA
        static let primaries: UInt32 = 0x55BB
        static let contentEncodings: UInt32 = 0x6D80
        static let contentEncoding: UInt32 = 0x6240
        static let contentEncodingScope: UInt32 = 0x5032
        static let contentEncodingType: UInt32 = 0x5033
        static let contentCompression: UInt32 = 0x5034
        static let contentCompAlgo: UInt32 = 0x4254
        static let contentCompSettings: UInt32 = 0x4255
        static let cluster: UInt32 = 0x1F43_B675
        static let timestamp: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let blockDuration: UInt32 = 0x9B
        static let referenceBlock: UInt32 = 0xFB
        static let cues: UInt32 = 0x1C53_BB6B
        static let chapters: UInt32 = 0x1043_A770
        static let tags: UInt32 = 0x1254_C367
        static let attachments: UInt32 = 0x1941_A469
        static let void: UInt32 = 0xEC

        /// Elements that sit directly in a Segment, and so end an unknown-size cluster.
        static let segmentLevel: Set<UInt32> = [cluster, seekHead, info, tracks, cues, chapters, tags, attachments, segment, ebml]
    }

    struct Header {
        var id: UInt32
        /// Nil for "unknown size", allowed for segments and clusters.
        var size: UInt64?
        var dataOffset: UInt64
    }

    struct Element {
        var id: UInt32
        var data: Data
    }

    /// A variable-length integer at `at`: its value and its length in bytes. With the marker
    /// kept it is an element ID; without, a size or number. Nil when the bytes don't form one.
    static func vint(_ bytes: [UInt8], at index: Int, keepMarker: Bool, maxLength: Int = 8) -> (value: (value: UInt64, isAllOnes: Bool), length: Int)? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= maxLength, index + length <= bytes.count else { return nil }
        var value = UInt64(keepMarker ? first : first & (0xFF >> length))
        for i in 1..<length { value = value << 8 | UInt64(bytes[index + i]) }
        let allOnes = !keepMarker && value == (UInt64(1) << (7 * UInt64(length))) - 1
        return ((value, allOnes), length)
    }

    /// The element header at `offset`, or nil at the end. Throws when the header is not EBML or
    /// its data would run past `end` (unknown sizes excepted).
    static func header(_ source: any MatroskaByteSource, at offset: UInt64, end: UInt64) throws -> Header? {
        guard offset < end else { return nil }
        let bytes = [UInt8](try source.read(at: offset, length: 12))
        guard !bytes.isEmpty else { return nil }
        guard let (id, idLength) = vint(bytes, at: 0, keepMarker: true, maxLength: 4),
              let (size, sizeLength) = vint(bytes, at: idLength, keepMarker: false)
        else { throw MatroskaError.damaged("element header at \(offset)") }
        let dataOffset = offset + UInt64(idLength + sizeLength)
        guard dataOffset <= end else { throw MatroskaError.damaged("element header past its parent at \(offset)") }
        return Header(id: UInt32(id.value), size: size.isAllOnes ? nil : size.value, dataOffset: dataOffset)
    }

    /// An element's data, read whole. A file that ends early gives what there is.
    static func body(_ source: any MatroskaByteSource, _ header: Header, size: UInt64) throws -> Data {
        guard size <= UInt64(Int.max) else { throw MatroskaError.tooLarge }
        return try source.read(at: header.dataOffset, length: Int(size))
    }

    /// The child elements of a master element's data. Children must have known sizes that fit.
    static func children(of data: Data) throws -> [Element] {
        let bytes = [UInt8](data)
        var elements: [Element] = []
        var p = 0
        while p < bytes.count {
            guard let (id, idLength) = vint(bytes, at: p, keepMarker: true, maxLength: 4),
                  let (size, sizeLength) = vint(bytes, at: p + idLength, keepMarker: false),
                  !size.isAllOnes, size.value <= UInt64(bytes.count - p - idLength - sizeLength)
            else { throw MatroskaError.damaged("child element") }
            let start = p + idLength + sizeLength
            let end = start + Int(size.value)
            elements.append(Element(id: UInt32(id.value), data: Data(bytes[start..<end])))
            p = end
        }
        return elements
    }

    static func uint(_ data: Data) -> UInt64? {
        guard data.count <= 8 else { return nil }
        return data.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    static func float(_ data: Data) -> Double? {
        guard let bits = uint(data) else { return nil }
        switch data.count {
        case 0: return 0
        case 4: return Double(Float(bitPattern: UInt32(bits)))
        case 8: return Double(bitPattern: bits)
        default: return nil
        }
    }

    /// Printable ASCII only, so a hostile file can't put control characters in a message.
    static func string(_ data: Data) -> String {
        let bytes = data.prefix { $0 != 0 }.filter { (0x20...0x7E).contains($0) }
        return String(decoding: bytes.prefix(128), as: UTF8.self)
    }
}
