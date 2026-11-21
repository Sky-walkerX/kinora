// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

/// Builds EBML by hand, for the shapes real files rarely have.
enum EBMLBuilder {
    static func id(_ id: UInt32) -> Data {
        let length = id > 0xFF_FFFF ? 4 : id > 0xFFFF ? 3 : id > 0xFF ? 2 : 1
        return Data((0..<length).reversed().map { UInt8(truncatingIfNeeded: id >> (8 * UInt32($0))) })
    }

    /// Sizes are written in the eight-byte form, which every reader must accept.
    static func element(_ elementID: UInt32, _ body: Data) -> Data {
        var size = Data([0x01])
        size += Data((0..<7).reversed().map { UInt8(truncatingIfNeeded: UInt64(body.count) >> (8 * UInt64($0))) })
        return id(elementID) + size + body
    }

    static func element(_ elementID: UInt32, uint value: UInt64) -> Data {
        element(elementID, Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }))
    }

    static func element(_ elementID: UInt32, string: String) -> Data { element(elementID, Data(string.utf8)) }

    static func unknownSize(_ elementID: UInt32) -> Data { id(elementID) + Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) }

    static func header(docType: String = "webm") -> Data {
        element(EBML.ID.ebml, element(EBML.ID.docType, string: docType))
    }

    static func videoTrack(number: UInt64 = 1, codec: String = "V_VP9", width: UInt64 = 96, height: UInt64 = 64,
                           defaultDuration: UInt64? = nil, extra: Data = Data()) -> Data {
        var fields = element(EBML.ID.trackNumber, uint: number) + element(EBML.ID.trackType, uint: 1)
            + element(EBML.ID.codecID, string: codec)
            + element(EBML.ID.video, element(EBML.ID.pixelWidth, uint: width) + element(EBML.ID.pixelHeight, uint: height))
        if let defaultDuration { fields += element(EBML.ID.defaultDuration, uint: defaultDuration) }
        return element(EBML.ID.trackEntry, fields + extra)
    }

    static func audioTrack(number: UInt64) -> Data {
        element(EBML.ID.trackEntry, element(EBML.ID.trackNumber, uint: number) + element(EBML.ID.trackType, uint: 2)
            + element(EBML.ID.codecID, string: "A_OPUS"))
    }

    static func block(track: UInt8 = 1, time: Int16, flags: UInt8, payload: Data) -> Data {
        let t = UInt16(bitPattern: time)
        return Data([0x80 | track, UInt8(t >> 8), UInt8(t & 0xFF), flags]) + payload
    }

    static func simpleBlock(track: UInt8 = 1, time: Int16, key: Bool, payload: Data) -> Data {
        element(EBML.ID.simpleBlock, block(track: track, time: time, flags: key ? 0x80 : 0, payload: payload))
    }

    static func cluster(time: UInt64, _ children: Data) -> Data {
        element(EBML.ID.cluster, element(EBML.ID.timestamp, uint: time) + children)
    }

    static func file(docType: String = "webm", tracks: Data, body: Data, info: Data? = nil) -> Data {
        let infoElement = info ?? element(EBML.ID.info, element(EBML.ID.timestampScale, uint: 1_000_000))
        return header(docType: docType) + element(EBML.ID.segment, infoElement + element(EBML.ID.tracks, tracks) + body)
    }
}

@Suite struct MatroskaReaderTests {
    typealias B = EBMLBuilder

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/containers", isDirectory: true)

    func read(_ data: Data) throws -> (MatroskaReader, [MatroskaFrame]) {
        let reader = try MatroskaReader(source: MatroskaDataSource(data))
        var frames: [MatroskaFrame] = []
        while let frame = try reader.nextFrame() { frames.append(frame) }
        return (reader, frames)
    }

    func fixture(_ name: String) throws -> (MatroskaReader, [MatroskaFrame]) {
        let reader = try MatroskaReader(source: try MatroskaFileSource(url: Self.fixtures.appendingPathComponent(name)))
        var frames: [MatroskaFrame] = []
        while let frame = try reader.nextFrame() { frames.append(frame) }
        return (reader, frames)
    }

    @Test(arguments: [
        ("vp9.webm", MatroskaCodec.vp9), ("vp9.mkv", .vp9), ("vp9-live.webm", .vp9), ("vp9-altref.webm", .vp9),
        ("vp9-10bit.webm", .vp9), ("vp9-alpha.webm", .vp9), ("vp8.webm", .vp8), ("av1.webm", .av1),
        ("h264.mkv", .h264), ("hevc.mkv", .hevc),
    ])
    func readsEveryFixtureFrame(name: String, codec: MatroskaCodec) throws {
        let (reader, frames) = try fixture(name)
        #expect(MatroskaCodec(codecID: reader.video.codecID) == codec)
        #expect(reader.video.pixelWidth == 96 && reader.video.pixelHeight == 64)
        #expect(reader.timestampScale == 1_000_000)
        #expect(frames.count == 10)
        #expect(frames.first?.isKey == true)
        // Ten frames a second for one second, in presentation order once sorted (H.264 and HEVC
        // store B-frames out of order).
        #expect(frames.map(\.time).sorted() == (0..<10).map { Int64($0) * 100_000_000 })
        #expect(reader.progress > 0.9)
        if !codec.reorders { #expect(frames.map(\.time) == frames.map(\.time).sorted()) }
    }

    @Test func liveFilesWithUnknownSizesRead() throws {
        // The fixture's segment and cluster have unknown sizes, as browser recordings do.
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("vp9-live.webm"))
        let segment = try #require(try EBML.header(MatroskaDataSource(data), at: 36, end: UInt64(data.count)))
        #expect(segment.id == EBML.ID.segment && segment.size == nil)
        #expect(try read(data).1.count == 10)
    }

    @Test func blockGroupsWithAdditionsRead() throws {
        // The alpha fixture stores frames in BlockGroups with BlockAdditions (the alpha plane).
        let (_, frames) = try fixture("vp9-alpha.webm")
        #expect(frames.filter(\.isKey).count == 1)
        #expect(VP9FrameHeader.parse(frames[0].data)?.isKeyFrame == true)
    }

    @Test func vp9HeadersAndConfiguration() throws {
        let (reader, frames) = try fixture("vp9.webm")
        let header = try #require(VP9FrameHeader.parse(frames[0].data))
        #expect(header.isKeyFrame && header.showFrame && header.profile == 0 && header.bitDepth == 8)
        #expect(header.width == 96 && header.height == 64 && header.subsamplingX && header.subsamplingY)
        #expect(VP9FrameHeader.parse(frames[1].data)?.isKeyFrame == false)
        let vpcC = try MatroskaCodec.vp9.configuration(for: reader.video, firstKeyFrame: frames[0].data, framesPerSecond: 10)
        // Version 1, no flags; profile 0, level 1; 8 bits, 4:2:0 co-sited, broadcast range;
        // colour unspecified (2) as the file doesn't say; no initialization data.
        #expect([UInt8](vpcC) == [1, 0, 0, 0, 0, 10, 0x82, 2, 2, 2, 0, 0])

        let (_, deep) = try fixture("vp9-10bit.webm")
        let tenBit = try #require(VP9FrameHeader.parse(deep[0].data))
        #expect(tenBit.profile == 2 && tenBit.bitDepth == 10)
    }

    @Test func superframesSplitIntoHiddenAndShownFrames() throws {
        let (_, frames) = try fixture("vp9-altref.webm")
        let packed = try #require(frames.first { VP9Superframe.frames(in: $0.data).count > 1 })
        let parts = VP9Superframe.frames(in: packed.data)
        #expect(parts.count == 2)
        let hidden = try #require(VP9FrameHeader.parse(packed.data.subdata(in: parts[0])))
        #expect(!hidden.showFrame)
        #expect(VP9FrameHeader.parse(packed.data.subdata(in: parts[1])) != nil)
        // A plain frame is one frame.
        #expect(VP9Superframe.frames(in: frames[0].data) == [0..<frames[0].data.count])
    }

    @Test func otherCodecsCarryTheirConfigurationRecords() throws {
        let (h264, h264Frames) = try fixture("h264.mkv")
        #expect(try MatroskaCodec.h264.configuration(for: h264.video, firstKeyFrame: h264Frames[0].data, framesPerSecond: 10).first == 1)
        let (hevc, _) = try fixture("hevc.mkv")
        #expect(try MatroskaCodec.hevc.configuration(for: hevc.video, firstKeyFrame: nil, framesPerSecond: 10).first == 1)
        let (av1, _) = try fixture("av1.webm")
        #expect(try MatroskaCodec.av1.configuration(for: av1.video, firstKeyFrame: nil, framesPerSecond: 10).first == 0x81)
        #expect(MatroskaCodec.vp8.fourCC == nil && MatroskaCodec.vp8.name == "VP8")
        #expect(MatroskaCodec(codecID: "V_THEORA").name == "THEORA")
        #expect(MatroskaCodec.vp9.fourCC == 0x7670_3039)
    }

    @Test func levelsFollowPictureSizeAndRate() {
        #expect(VP9Level.level(width: 96, height: 64, framesPerSecond: 10) == 10)
        #expect(VP9Level.level(width: 1920, height: 1080, framesPerSecond: 30) == 40)
        #expect(VP9Level.level(width: 1920, height: 1080, framesPerSecond: 60) == 41)
        #expect(VP9Level.level(width: 3840, height: 2160, framesPerSecond: 30) == 50)
        #expect(VP9Level.level(width: 8192, height: 8192, framesPerSecond: 120) == 62)
    }

    @Test func lacedBlocksSplitIntoFrames() throws {
        let tracks = B.videoTrack(defaultDuration: 40_000_000)
        // Xiph: 3 frames of 2, 300 and 1 bytes; sizes 2 and 300 (255 + 45) are written.
        let xiph = B.block(time: 0, flags: 0x80 | 0x02, payload: Data([2, 2, 255, 45]) + Data(count: 303))
        // EBML: 3 frames of 4, 6 and 5 bytes: first size 4, then +2 as a one-byte signed VINT.
        let ebml = B.block(time: 120, flags: 0x06, payload: Data([2, 0x84, 0x80 | (63 + 2)]) + Data(count: 15))
        // Fixed: 2 frames of 3 bytes.
        let fixed = B.block(time: 200, flags: 0x04, payload: Data([1]) + Data(count: 6))
        let body = B.cluster(time: 0, B.element(EBML.ID.simpleBlock, xiph) + B.element(EBML.ID.simpleBlock, ebml)
            + B.element(EBML.ID.simpleBlock, fixed))
        let (_, frames) = try read(B.file(tracks: tracks, body: body))
        #expect(frames.map(\.data.count) == [2, 300, 1, 4, 6, 5, 3, 3])
        // Laced frames after the first follow at the track's default duration.
        #expect(frames.map(\.time) == [0, 40, 80, 120, 160, 200, 200, 240].map { Int64($0) * 1_000_000 })
        #expect(frames.map(\.isKey) == [true, false, false, false, false, false, false, false])
    }

    @Test func damagedLacingIsRefused() {
        let tracks = B.videoTrack()
        let tooLong = B.block(time: 0, flags: 0x02, payload: Data([1, 200]) + Data(count: 10))
        #expect(throws: MatroskaError.self) {
            try read(B.file(tracks: tracks, body: B.cluster(time: 0, B.element(EBML.ID.simpleBlock, tooLong))))
        }
        let uneven = B.block(time: 0, flags: 0x04, payload: Data([1]) + Data(count: 5))
        #expect(throws: MatroskaError.self) {
            try read(B.file(tracks: tracks, body: B.cluster(time: 0, B.element(EBML.ID.simpleBlock, uneven))))
        }
    }

    @Test func blockGroupsUseReferencesForKeyframesAndCarryDurations() throws {
        let key = B.element(EBML.ID.blockGroup, B.element(EBML.ID.block, B.block(time: 0, flags: 0, payload: Data([1])))
            + B.element(EBML.ID.blockDuration, uint: 33))
        let delta = B.element(EBML.ID.blockGroup, B.element(EBML.ID.block, B.block(time: 33, flags: 0, payload: Data([2])))
            + B.element(EBML.ID.referenceBlock, Data([0xDF])))
        let (_, frames) = try read(B.file(tracks: B.videoTrack(), body: B.cluster(time: 1000, key + delta)))
        #expect(frames.map(\.isKey) == [true, false])
        #expect(frames.map(\.time) == [1_000_000_000, 1_033_000_000])
        #expect(frames[0].duration == 33_000_000)
    }

    @Test func otherTracksAreSkipped() throws {
        let tracks = B.audioTrack(number: 1) + B.videoTrack(number: 2)
        let body = B.cluster(time: 0, B.simpleBlock(track: 1, time: 0, key: true, payload: Data([9, 9]))
            + B.simpleBlock(track: 2, time: 0, key: true, payload: Data([7])))
        let (reader, frames) = try read(B.file(tracks: tracks, body: body))
        #expect(reader.video.number == 2)
        #expect(frames.map(\.data) == [Data([7])])
    }

    @Test func unknownSizeClustersEndAtTheNextTopLevelElement() throws {
        let first = B.unknownSize(EBML.ID.cluster) + B.element(EBML.ID.timestamp, uint: 0)
            + B.simpleBlock(time: 0, key: true, payload: Data([1])) + B.simpleBlock(time: 40, key: false, payload: Data([2]))
        let second = B.unknownSize(EBML.ID.cluster) + B.element(EBML.ID.timestamp, uint: 80)
            + B.simpleBlock(time: 0, key: false, payload: Data([3]))
        let cues = B.element(EBML.ID.cues, Data([0xEC, 0x80]))
        let tracks = B.element(EBML.ID.tracks, B.videoTrack())
        let info = B.element(EBML.ID.info, B.element(EBML.ID.timestampScale, uint: 1_000_000))
        let data = B.header() + B.unknownSize(EBML.ID.segment) + info + tracks + first + second + cues
        let (_, frames) = try read(data)
        #expect(frames.map(\.data) == [Data([1]), Data([2]), Data([3])])
        #expect(frames.map(\.time) == [0, 40_000_000, 80_000_000])
    }

    @Test func aCutOffFileGivesItsWholeFrames() throws {
        let body = B.cluster(time: 0, B.simpleBlock(time: 0, key: true, payload: Data(count: 50))
            + B.simpleBlock(time: 40, key: false, payload: Data(count: 50)))
        let whole = B.file(tracks: B.videoTrack(), body: body)
        let (_, frames) = try read(whole.prefix(whole.count - 10))
        #expect(frames.count == 1)
    }

    @Test func refusesWhatIsNotMatroska() {
        #expect(throws: MatroskaError.notMatroska) { try MatroskaReader(source: MatroskaDataSource(Data()))  }
        #expect(throws: MatroskaError.notMatroska) { try MatroskaReader(source: MatroskaDataSource(Data("RIFF....AVI LIST".utf8))) }
        #expect(throws: MatroskaError.notMatroska) {
            try MatroskaReader(source: MatroskaDataSource(B.file(docType: "notwebm", tracks: B.videoTrack(), body: Data())))
        }
        // An MP4 is not EBML.
        let mp4 = try? Data(contentsOf: Self.fixtures.appendingPathComponent("hevc.mp4"))
        #expect(throws: MatroskaError.notMatroska) { try MatroskaReader(source: MatroskaDataSource(mp4 ?? Data([0, 0, 0, 0x18]))) }
    }

    @Test func refusesFilesWithoutVideo() {
        #expect(throws: MatroskaError.noVideo) {
            try MatroskaReader(source: MatroskaDataSource(B.file(tracks: B.audioTrack(number: 1), body: Data())))
        }
    }

    @Test func refusesEncryptionButUndoesHeaderStripping() throws {
        let encrypted = B.element(EBML.ID.contentEncodings, B.element(EBML.ID.contentEncoding, B.element(EBML.ID.contentEncodingType, uint: 1)))
        #expect(throws: MatroskaError.protected) {
            try MatroskaReader(source: MatroskaDataSource(B.file(tracks: B.videoTrack(extra: encrypted), body: Data())))
        }
        let zlib = B.element(EBML.ID.contentEncodings, B.element(EBML.ID.contentEncoding,
            B.element(EBML.ID.contentCompression, B.element(EBML.ID.contentCompAlgo, uint: 0))))
        #expect(throws: MatroskaError.protected) {
            try MatroskaReader(source: MatroskaDataSource(B.file(tracks: B.videoTrack(extra: zlib), body: Data())))
        }
        let stripping = B.element(EBML.ID.contentEncodings, B.element(EBML.ID.contentEncoding, B.element(EBML.ID.contentCompression,
            B.element(EBML.ID.contentCompAlgo, uint: 3) + B.element(EBML.ID.contentCompSettings, Data([0xAA, 0xBB])))))
        let body = B.cluster(time: 0, B.simpleBlock(time: 0, key: true, payload: Data([1])))
        let (_, frames) = try read(B.file(tracks: B.videoTrack(extra: stripping), body: body))
        #expect(frames.map(\.data) == [Data([0xAA, 0xBB, 1])])
    }

    @Test func refusesSizesThatDontFit() {
        // A track entry claiming 16 bytes in a Tracks element holding 2.
        let badChild = B.header() + B.element(EBML.ID.segment, B.element(EBML.ID.tracks, Data([0xAE, 0x90, 1, 2])))
        #expect(throws: MatroskaError.self) { try MatroskaReader(source: MatroskaDataSource(badChild)) }
        // Pictures larger than Kinora converts.
        #expect(throws: MatroskaError.tooLarge) {
            try MatroskaReader(source: MatroskaDataSource(B.file(tracks: B.videoTrack(width: 20_000), body: Data())))
        }
        // Info with an impossible timestamp scale.
        let info = B.element(EBML.ID.info, B.element(EBML.ID.timestampScale, uint: 0))
        #expect(throws: MatroskaError.self) {
            try MatroskaReader(source: MatroskaDataSource(B.file(tracks: B.videoTrack(), body: Data(), info: info)))
        }
    }

    @Test func showsThePictureInItsDisplayShape() throws {
        let display = B.element(EBML.ID.video, B.element(EBML.ID.pixelWidth, uint: 720) + B.element(EBML.ID.pixelHeight, uint: 576)
            + B.element(EBML.ID.displayWidth, uint: 16) + B.element(EBML.ID.displayHeight, uint: 9))
        let track = B.element(EBML.ID.trackEntry, B.element(EBML.ID.trackNumber, uint: 1) + B.element(EBML.ID.trackType, uint: 1)
            + B.element(EBML.ID.codecID, string: "V_VP9") + display)
        let reader = try MatroskaReader(source: MatroskaDataSource(B.file(tracks: track, body: Data())))
        #expect(reader.video.shownSize.width == 720 && reader.video.shownSize.height == 405)
        let plain = try MatroskaReader(source: MatroskaDataSource(B.file(tracks: B.videoTrack(), body: Data())))
        #expect(plain.video.shownSize.width == 96 && plain.video.shownSize.height == 64)
    }

    @Test func codecNamesAreSafeToShow() {
        #expect(EBML.string(Data("V_\u{1B}[31mEVIL\n".utf8)) == "V_[31mEVIL")
        #expect(EBML.string(Data(repeating: 0x41, count: 1000)).count == 128)
    }
}
