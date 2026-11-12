// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AppKit
import AVFoundation
import KinoraKit

/// Converts an imported video once: HEVC, sized for the user's largest display, no audio
/// (wallpapers are silent), with the same orientation and frame timing as the source.
enum VideoOptimizer {
    enum Failure: Error { case noVideoTrack, cannotRead, cannotWrite(String) }

    /// The largest display's size in pixels, or a 1440p-class default without one.
    @MainActor static func largestDisplayPixels() -> CGSize {
        let sizes = NSScreen.screens.map { CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor) }
        return sizes.max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 2560, height: 1600)
    }

    /// Writes the optimized video to `destination`.
    static func optimize(_ source: URL, to destination: URL, display: CGSize) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        // Size the picture as it will be seen, then hand the writer the unrotated dimensions.
        let shown = natural.applying(transform)
        let shownSize = CGSize(width: abs(shown.width), height: abs(shown.height))
        let target = VideoOptimization.targetSize(source: shownSize, display: display)
        let rotated = abs(transform.b) == 1 && abs(transform.c) == 1
        let encoded = rotated ? CGSize(width: target.height, height: target.width) : target
        let bitrate = VideoOptimization.bitrate(width: target.width, height: target.height, framesPerSecond: Double(rate > 0 ? rate : 30))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.cannotRead }
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(encoded.width),
            AVVideoHeightKey: Int(encoded.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(rate > 0 ? rate.rounded() : 30),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any],
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.cannotWrite("the HEVC encoder refused the settings") }
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? Failure.cannotRead }
        guard writer.startWriting() else { throw writer.error ?? Failure.cannotWrite("could not start") }
        writer.startSession(atSourceTime: .zero)

        let pump = Pump(reader: reader, writer: writer, output: output, input: input)
        try await pump.run()
    }

    /// Moves samples from the reader to the writer on a queue of its own. AVFoundation's reader
    /// and writer are not Sendable; this object owns them and touches them only on its queue.
    private final class Pump: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let queue = DispatchQueue(label: "io.github.sky-walkerx.kinora.optimize")

        init(reader: AVAssetReader, writer: AVAssetWriter, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
            self.reader = reader
            self.writer = writer
            self.output = output
            self.input = input
        }

        func run() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while input.isReadyForMoreMediaData {
                        if let sample = output.copyNextSampleBuffer() {
                            if !input.append(sample) {
                                reader.cancelReading()
                                input.markAsFinished()
                                writer.cancelWriting()
                                continuation.resume(throwing: writer.error ?? Failure.cannotWrite("append failed"))
                                return
                            }
                        } else {
                            input.markAsFinished()
                            if reader.status == .failed {
                                writer.cancelWriting()
                                continuation.resume(throwing: reader.error ?? Failure.cannotRead)
                                return
                            }
                            writer.finishWriting { [self] in
                                if writer.status == .completed {
                                    continuation.resume()
                                } else {
                                    continuation.resume(throwing: writer.error ?? Failure.cannotWrite("finish failed"))
                                }
                            }
                            return
                        }
                    }
                }
            }
        }
    }
}
