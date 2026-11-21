// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import CoreMedia
import Foundation
import KinoraMedia
import Testing
import VideoToolbox

/// What this Mac's AVFoundation opens, for milestone 6's WebM question
/// (docs/spikes/2026-11-13-webm-and-web-wallpapers.md). The fixtures in Tests/Fixtures/containers
/// are one-second ffmpeg test patterns (testsrc2), made for this probe. It records rather than
/// asserts, except that HEVC in MP4, which Kinora relies on, must open and decode.
@Suite(.serialized) struct ContainerProbeTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/containers", isDirectory: true)

    struct Probe: CustomStringConvertible {
        var name: String
        var playable = false
        var videoTracks = 0
        var codec = "-"
        var decodedFrames = 0
        var error = "-"
        var description: String {
            "\(name): playable \(playable), video tracks \(videoTracks), codec \(codec), decoded frames \(decodedFrames), error \(error)"
        }
    }

    static func probe(_ name: String) async -> Probe {
        var result = Probe(name: name)
        let asset = AVURLAsset(url: fixtures.appendingPathComponent(name))
        do {
            result.playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            result.videoTracks = tracks.count
            guard let track = tracks.first else { return result }
            if let format = try await track.load(.formatDescriptions).first {
                let fourCC = CMFormatDescriptionGetMediaSubType(format)
                result.codec = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: fourCC >> $0) }, encoding: .ascii) ?? "\(fourCC)"
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            reader.add(output)
            if reader.startReading() {
                while let sample = output.copyNextSampleBuffer(), CMSampleBufferGetImageBuffer(sample) != nil {
                    result.decodedFrames += 1
                }
            }
            if let error = reader.error { result.error = error.localizedDescription }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    @Test func probeContainersAndCodecs() async throws {
        print("PROBE hardware decode: HEVC \(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)), VP9 \(VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)), AV1 \(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))")
        for name in ["hevc.mp4", "vp9.webm", "vp9.mkv", "vp8.webm", "av1.webm"] {
            let result = await Self.probe(name)
            print("PROBE \(result)")
            if name == "hevc.mp4" {
                #expect(result.playable && result.decodedFrames == 10, "Kinora's own format must open: \(result)")
            }
        }
        // The supplemental VP9 decoder is opt-in per process; see whether it changes anything.
        // Registered the way the app does it, once per process.
        MatroskaConverter.prepareDecoders()
        print("PROBE after registering the supplemental VP9 decoder: hardware VP9 \(VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9))")
        for name in ["vp9.webm", "vp9.mkv"] { print("PROBE (VP9 registered) \(await Self.probe(name))") }
    }
}
