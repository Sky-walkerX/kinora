// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// The video codecs a Matroska or WebM file may hold, and what VideoToolbox needs to decode them:
/// a four-character code and a codec configuration record, as an MP4 file would carry it.
public enum MatroskaCodec: Equatable, Sendable {
    case vp9, av1, h264, hevc, vp8
    case other(String)

    public init(codecID: String) {
        switch codecID {
        case "V_VP9": self = .vp9
        case "V_AV1": self = .av1
        case "V_MPEG4/ISO/AVC": self = .h264
        case "V_MPEGH/ISO/HEVC": self = .hevc
        case "V_VP8": self = .vp8
        default: self = .other(codecID)
        }
    }

    /// What people call it.
    public var name: String {
        switch self {
        case .vp9: "VP9"
        case .av1: "AV1"
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .vp8: "VP8"
        case .other(let id): id.hasPrefix("V_") ? String(id.dropFirst(2)) : id
        }
    }

    /// The codec type VideoToolbox decodes; nil for codecs macOS has no decoder for.
    public var fourCC: UInt32? {
        switch self {
        case .vp9: fourCharacterCode("vp09")
        case .av1: fourCharacterCode("av01")
        case .h264: fourCharacterCode("avc1")
        case .hevc: fourCharacterCode("hvc1")
        case .vp8, .other: nil
        }
    }

    /// The sample description extension that carries the configuration record.
    public var configurationAtom: String? {
        switch self {
        case .vp9: "vpcC"
        case .av1: "av1C"
        case .h264: "avcC"
        case .hevc: "hvcC"
        case .vp8, .other: nil
        }
    }

    /// True when frames can arrive out of presentation order (B-frames).
    public var reorders: Bool { self == .h264 || self == .hevc }

    /// The configuration record for the decoder. VP9's is built from the first keyframe, since
    /// WebM rarely stores one; the others come from CodecPrivate, checked for the right shape.
    public func configuration(for track: MatroskaVideoTrack, firstKeyFrame: Data?, framesPerSecond: Double) throws -> Data {
        switch self {
        case .vp9:
            guard let frame = firstKeyFrame,
                  let header = VP9Superframe.frames(in: frame).lazy.compactMap({ VP9FrameHeader.parse(frame.subdata(in: $0)) }).first(where: \.isKeyFrame)
            else { throw MatroskaError.damaged("no VP9 keyframe") }
            return VPCodecConfiguration(header: header, codecPrivate: track.codecPrivate, colour: track.colour,
                                        framesPerSecond: framesPerSecond).vpcC
        case .av1:
            // AV1CodecConfigurationRecord: marker and version 1, then profile, level and tier.
            guard let record = track.codecPrivate, record.count >= 4, record[record.startIndex] == 0x81 else {
                throw MatroskaError.damaged("AV1 configuration")
            }
            return record
        case .h264:
            guard let record = track.codecPrivate, record.count >= 7, record[record.startIndex] == 1 else {
                throw MatroskaError.damaged("avcC")
            }
            return record
        case .hevc:
            guard let record = track.codecPrivate, record.count >= 23, record[record.startIndex] == 1 else {
                throw MatroskaError.damaged("hvcC")
            }
            return record
        case .vp8, .other:
            throw MatroskaError.damaged("no decoder")
        }
    }
}

func fourCharacterCode(_ code: String) -> UInt32 {
    code.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
}

/// What a VP9 frame's uncompressed header says, for the fields a decoder configuration needs.
public struct VP9FrameHeader: Equatable, Sendable {
    public var profile: Int
    public var showExistingFrame = false
    public var isKeyFrame = false
    public var showFrame = false
    /// Known for keyframes only.
    public var bitDepth = 8
    /// VP9's color_space: 0 unknown, 1 BT.601, 2 BT.709, 3 SMPTE 170, 4 SMPTE 240, 5 BT.2020, 7 RGB.
    public var colorSpace = 0
    public var fullRange = false
    public var subsamplingX = true
    public var subsamplingY = true
    public var width = 0
    public var height = 0

    /// Nil when `data` doesn't start with a VP9 frame header.
    public static func parse(_ data: Data) -> VP9FrameHeader? {
        var bits = BitReader(Array(data.prefix(16)))
        guard bits.read(2) == 2, let low = bits.read(1), let high = bits.read(1) else { return nil }
        var header = VP9FrameHeader(profile: high << 1 | low)
        if header.profile == 3, bits.read(1) != 0 { return nil }
        guard let showExisting = bits.read(1) else { return nil }
        if showExisting == 1 {
            header.showExistingFrame = true
            header.showFrame = true
            return header
        }
        guard let frameType = bits.read(1), let show = bits.read(1), bits.read(1) != nil else { return nil }
        header.showFrame = show == 1
        guard frameType == 0 else { return header }
        header.isKeyFrame = true
        guard bits.read(24) == 0x49_8342 else { return nil }
        if header.profile >= 2 {
            guard let twelve = bits.read(1) else { return nil }
            header.bitDepth = twelve == 1 ? 12 : 10
        }
        guard let space = bits.read(3) else { return nil }
        header.colorSpace = space
        if space != 7 {
            guard let range = bits.read(1) else { return nil }
            header.fullRange = range == 1
            if header.profile == 1 || header.profile == 3 {
                guard let x = bits.read(1), let y = bits.read(1), bits.read(1) == 0 else { return nil }
                header.subsamplingX = x == 1
                header.subsamplingY = y == 1
            }
        } else {
            // RGB is 4:4:4, only in profiles 1 and 3.
            header.fullRange = true
            header.subsamplingX = false
            header.subsamplingY = false
            guard header.profile == 1 || header.profile == 3, bits.read(1) == 0 else { return nil }
        }
        guard let width = bits.read(16), let height = bits.read(16) else { return nil }
        header.width = width + 1
        header.height = height + 1
        return header
    }
}

/// VP9 packs a hidden frame and the frame shown after it into one "superframe", indexed at its end.
public enum VP9Superframe {
    /// The byte ranges of the frames in `data`: several for a superframe, else the whole of it.
    public static func frames(in data: Data) -> [Range<Int>] {
        let bytes = [UInt8](data)
        guard let marker = bytes.last, marker & 0xE0 == 0xC0 else { return [0..<bytes.count] }
        let count = Int(marker & 7) + 1
        let width = Int((marker >> 3) & 3) + 1
        let indexSize = 2 + width * count
        guard bytes.count >= indexSize, bytes[bytes.count - indexSize] == marker else { return [0..<bytes.count] }
        var ranges: [Range<Int>] = []
        var p = bytes.count - indexSize + 1
        var start = 0
        for _ in 0..<count {
            var size = 0
            for i in 0..<width { size |= Int(bytes[p + i]) << (8 * i) }
            p += width
            guard size > 0, start + size <= bytes.count - indexSize else { return [0..<bytes.count] }
            ranges.append(start..<(start + size))
            start += size
        }
        return ranges
    }
}

/// The VP9 codec configuration box ("vpcC", version 1) from the VP codec ISO media binding.
public struct VPCodecConfiguration: Equatable, Sendable {
    public var profile: Int
    public var level: Int
    public var bitDepth: Int
    /// 0 4:2:0 vertical, 1 4:2:0 co-sited, 2 4:2:2, 3 4:4:4.
    public var chromaSubsampling: Int
    public var fullRange: Bool
    public var primaries: Int
    public var transfer: Int
    public var matrix: Int

    public init(header: VP9FrameHeader, codecPrivate: Data?, colour: MatroskaVideoTrack.Colour?, framesPerSecond: Double) {
        profile = header.profile
        bitDepth = header.bitDepth
        switch (header.subsamplingX, header.subsamplingY) {
        case (true, true): chromaSubsampling = 1
        case (true, false): chromaSubsampling = 2
        default: chromaSubsampling = 3
        }
        fullRange = colour?.range.map { $0 == 2 } ?? header.fullRange
        let derivedMatrix = switch header.colorSpace {
        case 1, 3: 6
        case 2: 1
        case 4: 7
        case 5: 9
        case 7: 0
        default: 2
        }
        func known(_ value: Int?) -> Int? { value.flatMap { $0 == 2 || $0 > 255 ? nil : $0 } }
        matrix = known(colour?.matrixCoefficients) ?? derivedMatrix
        primaries = known(colour?.primaries) ?? (matrix == 1 ? 1 : matrix == 6 ? 6 : matrix == 9 ? 9 : 2)
        transfer = known(colour?.transferCharacteristics) ?? (matrix == 1 || matrix == 6 ? 1 : 2)
        level = VP9Level.level(width: header.width, height: header.height, framesPerSecond: framesPerSecond)
        // WebM's CodecPrivate for VP9, when present, is a list of ID, length, value features.
        if let codecPrivate {
            let bytes = [UInt8](codecPrivate)
            var p = 0
            while p + 2 <= bytes.count {
                let id = bytes[p], length = Int(bytes[p + 1])
                p += 2
                guard p + length <= bytes.count else { break }
                if length == 1 {
                    let value = Int(bytes[p])
                    switch id {
                    case 2 where VP9Level.levels.contains(where: { $0.level == value }): level = value
                    case 4 where value <= 3: chromaSubsampling = value
                    default: break
                    }
                }
                p += length
            }
        }
    }

    /// The box's contents: version and flags, then the record, with no codec initialization data.
    public var vpcC: Data {
        Data([
            1, 0, 0, 0,
            UInt8(clamping: profile), UInt8(clamping: level),
            UInt8(clamping: bitDepth) << 4 | UInt8(clamping: chromaSubsampling) << 1 | (fullRange ? 1 : 0),
            UInt8(clamping: primaries), UInt8(clamping: transfer), UInt8(clamping: matrix),
            0, 0,
        ])
    }
}

/// VP9 levels (VP9 bitstream specification, annex A): the lowest whose picture size and luma
/// sample rate fit.
public enum VP9Level {
    static let levels: [(level: Int, sampleRate: Double, pictureSize: Int)] = [
        (10, 829_440, 36_864), (11, 2_764_800, 73_728), (20, 4_608_000, 122_880), (21, 9_216_000, 245_760),
        (30, 20_736_000, 552_960), (31, 36_864_000, 983_040), (40, 83_558_400, 2_228_224), (41, 160_432_128, 2_228_224),
        (50, 311_951_360, 8_912_896), (51, 588_251_136, 8_912_896), (52, 1_176_502_272, 8_912_896),
        (60, 1_176_502_272, 35_651_584), (61, 2_353_004_544, 35_651_584), (62, 4_706_009_088, 35_651_584),
    ]

    public static func level(width: Int, height: Int, framesPerSecond: Double) -> Int {
        let picture = max(1, width) * max(1, height)
        let rate = Double(picture) * (framesPerSecond.isFinite && framesPerSecond > 0 ? framesPerSecond : 30)
        return levels.first { picture <= $0.pictureSize && rate <= $0.sampleRate }?.level ?? 62
    }
}

/// Reads bits most significant first.
struct BitReader {
    private let bytes: [UInt8]
    private var bit = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int? {
        guard count > 0, count <= 32, bit + count <= bytes.count * 8 else { return nil }
        var value = 0
        for _ in 0..<count {
            value = value << 1 | Int(bytes[bit >> 3] >> (7 - UInt8(bit & 7)) & 1)
            bit += 1
        }
        return value
    }
}
