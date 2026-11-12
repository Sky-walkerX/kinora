// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import ImageIO
import IOSurface
import KinoraKit
import QuartzCore

/// One wallpaper surface: a looping video in a remote layer tree. A still of the wallpaper sits
/// on top until the first video frame is ready, so the surface never shows black.
@MainActor final class VideoSurface {
    private let context: RemoteContext
    private let root = CALayer()
    private let still = CALayer()
    private let playerLayer = AVPlayerLayer()
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var readyObservation: NSKeyValueObservation?
    private var media: URL?
    private var frameCap: Int?
    private var stillImage: CGImage?
    private(set) var itemID: UUID?

    init?(destination: WallpaperDestination) {
        guard let context = RemoteContext() else { return nil }
        self.context = context
        root.backgroundColor = CGColor(gray: 0.08, alpha: 1)
        root.masksToBounds = true
        still.contentsGravity = .resizeAspectFill
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.opacity = 0
        root.addSublayer(playerLayer)
        root.addSublayer(still)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        playerLayer.player = player
        resize(to: destination)
        context.host(root)
    }

    var contextID: UInt32 { context.contextID }

    func resize(to destination: WallpaperDestination) {
        let size = destination.size ?? CGSize(width: 1440, height: 900)
        let scale = CGFloat(destination.scaleFactor ?? 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [root, still, playerLayer] {
            layer.frame = CGRect(origin: .zero, size: size)
            layer.contentsScale = scale
        }
        CATransaction.commit()
    }

    /// Shows a library item, starting from its still.
    func show(itemID: UUID, media: URL, thumbnail: URL, frameCap: Int?) {
        guard itemID != self.itemID || media != self.media else { return }
        self.itemID = itemID
        self.media = media
        stillImage = Self.image(at: thumbnail)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.contents = stillImage
        still.opacity = 1
        playerLayer.opacity = 0
        CATransaction.commit()
        startPlayback(frameCap: frameCap)
    }

    /// Plays, capped, or holds the current frame.
    func apply(_ decision: PlaybackDecision) {
        switch decision {
        case .play(let cap):
            if cap != frameCap { startPlayback(frameCap: cap) }
            if player.rate == 0 { player.play() }
        case .pause:
            player.pause()
        }
    }

    var isPlaying: Bool { player.rate != 0 }

    /// The frame on screen now, drawn into an IOSurface of the destination's pixel size.
    func snapshot(pixelSize: (width: Int, height: Int)) async -> IOSurfaceRef? {
        var image: CGImage?
        if let asset = player.currentItem?.asset {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            image = try? await generator.image(at: player.currentTime()).image
        }
        guard let frame = image ?? stillImage else { return nil }
        return Self.surface(drawing: frame, width: pixelSize.width, height: pixelSize.height)
    }

    func tearDown() {
        readyObservation = nil
        player.pause()
        player.removeAllItems()
        looper = nil
        context.invalidate()
    }

    // MARK: - Playback

    private func startPlayback(frameCap: Int?) {
        guard let media else { return }
        self.frameCap = frameCap
        let wasPlaying = isPlaying
        player.pause()
        looper = nil
        player.removeAllItems()
        let asset = AVURLAsset(url: media)
        let template = AVPlayerItem(asset: asset)
        if let frameCap {
            // A video composition renders at most frameCap frames a second. Only worth its cost
            // when the video is faster than the cap.
            Task { @MainActor [weak self] in
                guard let self, self.frameCap == frameCap, self.media == media else { return }
                if let rate = try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate),
                   Double(rate) > Double(frameCap) + 1,
                   var composition = try? await AVVideoComposition.Configuration(for: asset) {
                    // An invalid timing track makes frameDuration the maximum output rate.
                    composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
                    composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameCap))
                    template.videoComposition = AVVideoComposition(configuration: composition)
                }
                self.loop(template, resume: wasPlaying)
            }
        } else {
            loop(template, resume: wasPlaying)
        }
    }

    private func loop(_ template: AVPlayerItem, resume: Bool) {
        // AVPlayerLooper queues copies of the item back to back, so the loop has no gap.
        looper = AVPlayerLooper(player: player, templateItem: template)
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in self?.revealVideo() }
        }
        if resume { player.play() }
    }

    private func revealVideo() {
        guard playerLayer.opacity < 1 else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        playerLayer.opacity = 1
        still.opacity = 0
        CATransaction.commit()
    }

    // MARK: - Images

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Draws `image` aspect-filled into a new BGRA IOSurface.
    static func surface(drawing image: CGImage, width: Int, height: Int) -> IOSurfaceRef? {
        guard width > 0, height > 0,
              let surface = IOSurfaceCreate([kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
                                             kIOSurfacePixelFormat: 0x4247_5241 /* 'BGRA' */] as CFDictionary)
        else { return nil }
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: IOSurfaceGetBaseAddress(surface), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: IOSurfaceGetBytesPerRow(surface), space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (CGFloat(width) - drawn.width) / 2, y: (CGFloat(height) - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        return surface
    }
}
