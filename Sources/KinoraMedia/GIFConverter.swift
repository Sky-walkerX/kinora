// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import KinoraKit

/// Turns an animated GIF into a looping HEVC video once, at import, so it plays through the
/// hardware video decoder like any other wallpaper instead of decoding GIF frames forever.
public enum GIFConverter {
    public enum Failure: Error, Equatable {
        case notAnimated, tooLarge, encoderUnavailable, writeFailed
    }

    /// GIFs larger than this on their longest side are scaled down.
    public static let maxSide = 3840
    public static let maxFrames = 3000

    /// Frame durations as GIF players show them: delays under 20 ms count as 100 ms.
    public static func frameDelays(_ source: CGImageSource) -> [Double] {
        (0..<CGImageSourceGetCount(source)).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
            return delay < 0.02 ? 0.1 : delay
        }
    }

    /// Writes `destination` from the GIF at `source`. Each frame lasts as long as the GIF says.
    public static func convert(_ source: URL, to destination: URL) throws {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.notAnimated
        }
        let count = CGImageSourceGetCount(image)
        guard count > 1 else { throw Failure.notAnimated }
        guard count <= maxFrames else { throw Failure.tooLarge }
        guard let first = CGImageSourceCreateImageAtIndex(image, 0, nil) else { throw Failure.notAnimated }
        let scale = min(1, Double(maxSide) / Double(max(first.width, first.height)))
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded(.down)) * 2) }
        let width = even(Double(first.width) * scale), height = even(Double(first.height) * scale)
        let delays = frameDelays(image)

        try? FileManager.default.removeItem(at: destination)
        guard let writer = try? AVAssetWriter(outputURL: destination, fileType: .mov) else { throw Failure.writeFailed }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: VideoOptimization.bitrate(width: Double(width), height: Double(height), framesPerSecond: 15),
            ],
        ]
        var chosen = settings
        if !writer.canApply(outputSettings: settings, forMediaType: .video) { chosen[AVVideoCodecKey] = AVVideoCodecType.h264 }
        guard writer.canApply(outputSettings: chosen, forMediaType: .video) else { throw Failure.encoderUnavailable }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: chosen)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure.encoderUnavailable }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writeFailed }
        writer.startSession(atSourceTime: .zero)

        func fail() -> Failure {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            return .writeFailed
        }
        var time = 0.0
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for index in 0..<count {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                guard waited < 30_000, writer.status != .failed else { throw fail() }
                usleep(1000)
                waited += 1
            }
            guard let frame = CGImageSourceCreateImageAtIndex(image, index, nil), let pool = adaptor.pixelBufferPool else { throw fail() }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw fail() }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            // Transparent GIF pixels become black, as they would over a dark desktop.
            context?.setFillColor(CGColor(gray: 0, alpha: 1))
            context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context?.interpolationQuality = .high
            context?.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard context != nil, adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) else { throw fail() }
            time += delays[index]
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.writeFailed
        }
    }
}
