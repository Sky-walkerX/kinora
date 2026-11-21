// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import CoreMedia
import Foundation
import KinoraKit
import VideoToolbox

/// Why a WebM or Matroska video could not be converted, in words for the user.
public enum MatroskaConversionError: Error, Equatable, Sendable, CustomStringConvertible {
    case notMatroska, damaged, noVideo, protected, tooLarge, tooLong
    /// A codec macOS has no decoder for, such as VP8.
    case unsupportedCodec(String)
    /// A codec this Mac can't decode, such as AV1 without an AV1 decoder.
    case decoderUnavailable(String)
    case nothingDecoded
    case encoderUnavailable
    case writeFailed
    case cancelled

    public init(_ error: MatroskaError) {
        switch error {
        case .notMatroska: self = .notMatroska
        case .damaged: self = .damaged
        case .noVideo: self = .noVideo
        case .protected: self = .protected
        case .tooLarge: self = .tooLarge
        }
    }

    public var description: String {
        switch self {
        case .notMatroska: "It isn't a WebM or Matroska video Kinora can read."
        case .damaged: "The video file is damaged or incomplete."
        case .noVideo: "It has no video in it."
        case .protected: "Its video is encrypted, or packed in a way Kinora can't undo."
        case .tooLarge: "Its picture is larger than Kinora converts (8192 pixels on the longest side)."
        case .tooLong: "It's longer than Kinora converts (an hour)."
        case .unsupportedCodec(let name): "Its video is \(name), which macOS can't decode. Convert it to MP4 (H.264 or HEVC) first."
        case .decoderUnavailable(let name): "This Mac can't decode \(name) video. Convert it to MP4 (H.264 or HEVC) first."
        case .nothingDecoded: "macOS couldn't decode any of its frames. Convert it to MP4 (H.264 or HEVC) first."
        case .encoderUnavailable: "This Mac couldn't encode the converted video."
        case .writeFailed: "Kinora couldn't write the converted video."
        case .cancelled: "The conversion was stopped."
        }
    }
}

/// What a conversion did.
public struct MatroskaConversion: Equatable, Sendable {
    /// The source's codec, as people call it.
    public var sourceCodec: String
    /// "hevc" or "h264".
    public var codec: String
    public var frames: Int
    public var width: Int
    public var height: Int
    public var seconds: Double
    /// Frames the decoder refused; the rest were kept.
    public var skippedFrames: Int
}

/// Converts a WebM or Matroska video, which AVFoundation can't open, into HEVC once, at import.
/// Kinora's own reader takes the frames out of the container; VideoToolbox decodes them (VP9,
/// AV1 where the Mac has a decoder, H.264 and HEVC); the result is sized for the display like
/// any imported video and then plays through the ordinary video path. Nothing here needs FFmpeg.
public enum MatroskaConverter {
    /// An hour at 30 frames a second.
    public static let maxFrames = 108_000
    /// Most frames H.264 and HEVC hold back before showing (their largest picture buffer).
    static let reorderDepth = 16

    /// True for files named or shaped like Matroska or WebM.
    public static func isMatroska(_ url: URL) -> Bool {
        if ["webm", "mkv", "mk3d"].contains(url.pathExtension.lowercased()) { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x1A, 0x45, 0xDF, 0xA3])
    }

    /// Writes `destination` from `source`. Cancelling the task stops the work and removes what it
    /// wrote. `progress` runs on a background thread with values from 0 to 1.
    public static func convert(_ source: URL, to destination: URL, display: CGSize,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> MatroskaConversion {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MatroskaConversion, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try convertNow(source, to: destination, display: display, flag: flag, progress: progress))
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        continuation.resume(throwing: flag.isCancelled ? MatroskaConversionError.cancelled : error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    static func convertNow(_ source: URL, to destination: URL, display: CGSize, flag: CancellationFlag,
                           progress: (Double) -> Void) throws -> MatroskaConversion {
        let reader: MatroskaReader
        do {
            reader = try MatroskaReader(source: try MatroskaFileSource(url: source))
        } catch let error as MatroskaError {
            throw MatroskaConversionError(error)
        } catch {
            throw MatroskaConversionError.notMatroska
        }
        func next() throws -> MatroskaFrame? {
            do { return try reader.nextFrame() } catch let error as MatroskaError { throw MatroskaConversionError(error) }
        }
        let track = reader.video
        let codec = MatroskaCodec(codecID: track.codecID)
        guard let codecType = codec.fourCC, let atom = codec.configurationAtom else {
            throw MatroskaConversionError.unsupportedCodec(codec.name)
        }

        // Decoding starts at the first keyframe.
        var first: MatroskaFrame?
        while let frame = try next() {
            if flag.isCancelled { throw MatroskaConversionError.cancelled }
            if frame.isKey { first = frame; break }
        }
        guard let first else { throw MatroskaConversionError.nothingDecoded }
        let framesPerSecond = track.defaultDuration.map { 1e9 / Double($0) }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 30
        let record: Data
        do {
            record = try codec.configuration(for: track, firstKeyFrame: first.data, framesPerSecond: framesPerSecond)
        } catch {
            throw MatroskaConversionError.damaged
        }

        // VP9's decoder is supplemental: each process asks for it.
        if codec == .vp9 { VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9) }
        var formatOut: CMVideoFormatDescription?
        let extensions: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: record] as CFDictionary]
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codecType, width: Int32(track.pixelWidth),
                                             height: Int32(track.pixelHeight), extensions: extensions as CFDictionary,
                                             formatDescriptionOut: &formatOut) == noErr,
              let format = formatOut
        else { throw MatroskaConversionError.damaged }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
        ]
        var sessionOut: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &sessionOut) == noErr,
              let session = sessionOut
        else { throw MatroskaConversionError.decoderUnavailable(codec.name) }
        defer { VTDecompressionSessionInvalidate(session) }

        // The writer, sized for the display in the picture's intended shape.
        let shown = track.shownSize
        let target = VideoOptimization.targetSize(source: CGSize(width: shown.width, height: shown.height), display: display)
        let width = Int(target.width), height = Int(target.height)
        try? FileManager.default.removeItem(at: destination)
        guard let writer = try? AVAssetWriter(outputURL: destination, fileType: .mov) else { throw MatroskaConversionError.writeFailed }
        func settings(_ type: AVVideoCodecType) -> [String: Any] {
            [
                AVVideoCodecKey: type, AVVideoWidthKey: width, AVVideoHeightKey: height,
                // The stored pixels may have another shape than the picture (anamorphic video).
                AVVideoScalingModeKey: AVVideoScalingModeResize,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: VideoOptimization.bitrate(width: target.width, height: target.height, framesPerSecond: framesPerSecond),
                    AVVideoExpectedSourceFrameRateKey: Int(framesPerSecond.rounded()),
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                ] as [String: Any],
            ]
        }
        let outputCodec: AVVideoCodecType
        if writer.canApply(outputSettings: settings(.hevc), forMediaType: .video) {
            outputCodec = .hevc
        } else if writer.canApply(outputSettings: settings(.h264), forMediaType: .video) {
            outputCodec = .h264
        } else {
            throw MatroskaConversionError.encoderUnavailable
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings(outputCodec))
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw MatroskaConversionError.encoderUnavailable }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { throw MatroskaConversionError.writeFailed }
        writer.startSession(atSourceTime: .zero)
        func abandon(_ error: MatroskaConversionError) -> MatroskaConversionError {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            return error
        }

        let decoded = DecodedFrames()
        var waiting: [(time: CMTime, buffer: CVPixelBuffer)] = []
        var origin: CMTime?
        var lastAppended: CMTime?
        var appended = 0, skipped = 0, read = 0
        let step = CMTime(value: CMTimeValue((1e9 / framesPerSecond).rounded()), timescale: 1_000_000_000)

        func append(_ frame: (time: CMTime, buffer: CVPixelBuffer)) throws {
            let start = origin ?? frame.time
            origin = start
            let time = CMTimeSubtract(frame.time, start)
            // Frames must move forward; a repeated or earlier time would make the writer fail.
            if let lastAppended, CMTimeCompare(time, lastAppended) <= 0 { return }
            var waited = 0
            while !input.isReadyForMoreMediaData {
                if flag.isCancelled { throw abandon(.cancelled) }
                if writer.status == .failed || waited > 30_000 { throw abandon(.writeFailed) }
                usleep(1000)
                waited += 1
            }
            guard adaptor.append(frame.buffer, withPresentationTime: time) else { throw abandon(.writeFailed) }
            lastAppended = time
            appended += 1
        }
        /// Moves decoded frames into time order, passing on those no later frame can precede.
        func drain(keeping depth: Int) throws {
            waiting.append(contentsOf: decoded.take())
            waiting.sort { CMTimeCompare($0.time, $1.time) < 0 }
            while waiting.count > depth { try append(waiting.removeFirst()) }
        }

        var frame: MatroskaFrame? = first
        while let current = frame {
            if flag.isCancelled { throw abandon(.cancelled) }
            read += 1
            guard read <= maxFrames else { throw abandon(.tooLong) }
            if let sample = Self.sampleBuffer(current, format: format, duration: step) {
                var flags: VTDecodeFrameFlags = []
                if current.isInvisible { flags.insert(._DoNotOutputFrame) }
                var info = VTDecodeInfoFlags()
                let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: &info) { status, infoFlags, image, time, _ in
                    decoded.add(status: status, dropped: infoFlags.contains(.frameDropped), image: image, time: time)
                }
                if status != noErr { skipped += 1 }
            } else {
                skipped += 1
            }
            try drain(keeping: codec.reorders ? Self.reorderDepth : 0)
            if read % 15 == 0 { progress(min(0.98, reader.progress)) }
            frame = try next()
        }
        VTDecompressionSessionFinishDelayedFrames(session)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        try drain(keeping: 0)
        skipped += decoded.failures
        guard appended > 0, let lastAppended else { throw abandon(appended == 0 && skipped > 0 ? .decoderUnavailable(codec.name) : .nothingDecoded) }

        input.markAsFinished()
        // The last frame lasts one frame.
        let end = CMTimeAdd(lastAppended, step)
        writer.endSession(atSourceTime: end)
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw abandon(.writeFailed) }
        progress(1)
        return MatroskaConversion(sourceCodec: codec.name, codec: outputCodec == .hevc ? "hevc" : "h264", frames: appended,
                                  width: width, height: height, seconds: end.seconds, skippedFrames: skipped)
    }

    /// A frame as a sample for the decoder, timed in nanoseconds.
    static func sampleBuffer(_ frame: MatroskaFrame, format: CMVideoFormatDescription, duration: CMTime) -> CMSampleBuffer? {
        let length = frame.data.count
        guard length > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              frame.data.withUnsafeBytes({ bytes in
                  bytes.baseAddress.map { CMBlockBufferReplaceDataBytes(with: $0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) } ?? -1
              }) == noErr
        else { return nil }
        let frameDuration = frame.duration.map { CMTime(value: $0, timescale: 1_000_000_000) } ?? duration
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: CMTime(value: frame.time, timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var size = length
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }
}

/// Frames the decoder hands back, possibly from another thread.
private final class DecodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(time: CMTime, buffer: CVPixelBuffer)] = []
    private var failed = 0

    var failures: Int { lock.withLock { failed } }

    func add(status: OSStatus, dropped: Bool, image: CVImageBuffer?, time: CMTime) {
        lock.withLock {
            if status == noErr, !dropped, let image, time.isValid {
                frames.append((time, image))
            } else if status != noErr {
                failed += 1
            }
        }
    }

    func take() -> [(time: CMTime, buffer: CVPixelBuffer)] {
        lock.withLock {
            defer { frames.removeAll() }
            return frames
        }
    }
}
