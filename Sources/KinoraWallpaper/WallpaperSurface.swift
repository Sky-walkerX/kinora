// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AVFoundation
import ImageIO
import IOSurface
import KinoraKit
import KinoraRender
import QuartzCore

/// What a surface shows: a looping video or one of Kinora's originals.
@MainActor protocol SurfaceContent: AnyObject {
    var layer: CALayer { get }
    var itemID: UUID { get }
    func resize(to size: CGSize, scale: CGFloat)
    func apply(_ decision: PlaybackDecision)
    /// The frame on screen now, at the given pixel size.
    func snapshot(width: Int, height: Int) async -> IOSurfaceRef?
    func tearDown()
}

/// One wallpaper surface: a remote layer tree WallpaperAgent hosts, whose content can change
/// between videos and originals without a new context, so macOS never has to re-acquire it.
@MainActor final class WallpaperSurface {
    private let context: RemoteContext
    private let root = CALayer()
    private var content: SurfaceContent?
    private var size = CGSize(width: 1440, height: 900)
    private var scale: CGFloat = 2
    private var lastDecision: PlaybackDecision = .pause(.settled)

    init?(destination: WallpaperDestination) {
        guard let context = RemoteContext() else { return nil }
        self.context = context
        root.backgroundColor = CGColor(gray: 0.08, alpha: 1)
        root.masksToBounds = true
        resize(to: destination)
        context.host(root)
    }

    var contextID: UInt32 { context.contextID }
    var itemID: UUID? { content?.itemID }

    func resize(to destination: WallpaperDestination) {
        size = destination.size ?? CGSize(width: 1440, height: 900)
        scale = CGFloat(destination.scaleFactor ?? 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = scale
        content?.resize(to: size, scale: scale)
        CATransaction.commit()
    }

    /// Shows a library video, starting from its still.
    func showVideo(itemID: UUID, media: URL, thumbnail: URL, frameCap: Int?) {
        if let video = content as? VideoContent, video.itemID == itemID, video.media == media { return }
        replace(with: VideoContent(itemID: itemID, media: media, thumbnail: thumbnail, frameCap: frameCap))
    }

    /// Shows a still picture.
    func showStill(itemID: UUID, media: URL) {
        if let still = content as? StillContent, still.itemID == itemID, still.media == media { return }
        replace(with: StillContent(itemID: itemID, media: media))
    }

    /// Shows one of Kinora's originals. Returns false where Metal is unavailable.
    @discardableResult
    func showOriginal(_ original: KinoraOriginal, settings: PlaybackSettings, location: ApproximateLocation.Coordinates) -> Bool {
        if let shader = content as? ShaderContent, shader.itemID == original.id {
            shader.update(settings: settings)
            return true
        }
        guard let renderer = OriginalRenderer.shared,
              let shader = ShaderContent(original: original, renderer: renderer, settings: settings, location: location) else { return false }
        replace(with: shader)
        return true
    }

    /// Plays, capped, or holds the current frame.
    func apply(_ decision: PlaybackDecision) {
        lastDecision = decision
        content?.apply(decision)
    }

    var isPlaying: Bool {
        if case .play = lastDecision { return content != nil }
        return false
    }

    /// The frame on screen now, drawn into an IOSurface of the destination's pixel size.
    func snapshot(pixelSize: (width: Int, height: Int)) async -> IOSurfaceRef? {
        await content?.snapshot(width: pixelSize.width, height: pixelSize.height)
    }

    func tearDown() {
        content?.tearDown()
        content = nil
        context.invalidate()
    }

    /// Puts new content on top and fades it in over the old, which is then released.
    private func replace(with next: SurfaceContent) {
        let previous = content
        content = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        next.resize(to: size, scale: scale)
        next.layer.opacity = previous == nil ? 1 : 0
        root.addSublayer(next.layer)
        CATransaction.commit()
        next.apply(lastDecision)
        guard let previous else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.5)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                previous.tearDown()
                previous.layer.removeFromSuperlayer()
            }
        }
        next.layer.opacity = 1
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

/// A looping video. A still of the wallpaper sits on top until the first video frame is ready,
/// so the surface never shows black.
@MainActor final class VideoContent: SurfaceContent {
    let layer = CALayer()
    let itemID: UUID
    let media: URL
    private let still = CALayer()
    private let playerLayer = AVPlayerLayer()
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var readyObservation: NSKeyValueObservation?
    private var frameCap: Int?
    private var stillImage: CGImage?

    init(itemID: UUID, media: URL, thumbnail: URL, frameCap: Int?) {
        self.itemID = itemID
        self.media = media
        layer.masksToBounds = true
        still.contentsGravity = .resizeAspectFill
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.opacity = 0
        layer.addSublayer(playerLayer)
        layer.addSublayer(still)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        playerLayer.player = player
        stillImage = WallpaperSurface.image(at: thumbnail)
        still.contents = stillImage
        startPlayback(frameCap: frameCap, resume: false)
    }

    func resize(to size: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [layer, still, playerLayer] {
            sublayer.frame = CGRect(origin: .zero, size: size)
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
    }

    func apply(_ decision: PlaybackDecision) {
        switch decision {
        case .play(let cap):
            if cap != frameCap { startPlayback(frameCap: cap, resume: true) }
            if player.rate == 0 { player.play() }
        case .pause:
            player.pause()
        }
    }

    func snapshot(width: Int, height: Int) async -> IOSurfaceRef? {
        var image: CGImage?
        if let asset = player.currentItem?.asset {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            image = try? await generator.image(at: player.currentTime()).image
        }
        guard let frame = image ?? stillImage else { return nil }
        return WallpaperSurface.surface(drawing: frame, width: width, height: height)
    }

    func tearDown() {
        readyObservation = nil
        player.pause()
        player.removeAllItems()
        looper = nil
    }

    private func startPlayback(frameCap: Int?, resume: Bool) {
        self.frameCap = frameCap
        let wasPlaying = resume && player.rate != 0
        player.pause()
        looper = nil
        player.removeAllItems()
        let asset = AVURLAsset(url: media)
        let template = AVPlayerItem(asset: asset)
        if let frameCap {
            // A video composition renders at most frameCap frames a second. Only worth its cost
            // when the video is faster than the cap.
            Task { @MainActor [weak self] in
                guard let self, self.frameCap == frameCap else { return }
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
}

/// A still picture. Costs nothing once drawn: no decoder, no timer.
@MainActor final class StillContent: SurfaceContent {
    let layer = CALayer()
    let itemID: UUID
    let media: URL
    private var image: CGImage?
    private var decodedSide = 0

    init(itemID: UUID, media: URL) {
        self.itemID = itemID
        self.media = media
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
    }

    func resize(to size: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(origin: .zero, size: size)
        layer.contentsScale = scale
        // Decode once at the size shown, not at the file's full size.
        let side = Int((max(size.width, size.height) * scale).rounded())
        if image == nil || side > decodedSide {
            image = Self.decode(media, maxSide: side)
            decodedSide = side
            layer.contents = image
        }
        CATransaction.commit()
    }

    func apply(_ decision: PlaybackDecision) {}

    func snapshot(width: Int, height: Int) async -> IOSurfaceRef? {
        guard let image = image ?? Self.decode(media, maxSide: max(width, height)) else { return nil }
        return WallpaperSurface.surface(drawing: image, width: width, height: height)
    }

    func tearDown() {
        layer.contents = nil
        image = nil
    }

    static func decode(_ url: URL, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, min(16_384, maxSide)),
        ] as CFDictionary)
    }
}
