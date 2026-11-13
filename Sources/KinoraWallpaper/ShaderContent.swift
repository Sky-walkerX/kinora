// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import IOSurface
import KinoraKit
import KinoraRender
import Metal
import QuartzCore

/// One of Kinora's originals, drawn live with Metal into a layer WallpaperAgent hosts.
///
/// It draws only while playing, at the original's own frame rate capped by the user's rules,
/// into a drawable a fraction of the display's size. Paused, it draws nothing and the last
/// frame stays on screen. The motion's clock advances only while playing, so resuming
/// continues where it stopped.
@MainActor final class ShaderContent: SurfaceContent {
    let layer: CALayer
    let itemID: UUID
    private let metalLayer = CAMetalLayer()
    private let original: KinoraOriginal
    private let renderer: OriginalRenderer
    private var settings: PlaybackSettings
    private let location: ApproximateLocation.Coordinates
    private var pixelSize = (width: 2880, height: 1800)
    private var timer: Timer?
    private var framesPerSecond = 0
    /// Seconds of motion shown so far, and when the current run of frames began.
    private var motionTime: Double
    private var runStarted: CFTimeInterval?
    private let inFlight = InFlight()
    /// Set when WallpaperAgent stopped taking frames (a drawable took too long to arrive), so
    /// the plug-in backs off instead of stalling its main thread on every frame.
    private var backOffUntil: CFTimeInterval = 0

    init?(original: KinoraOriginal, renderer: OriginalRenderer, settings: PlaybackSettings, location: ApproximateLocation.Coordinates) {
        // Fail here, not on the first frame, when the shader cannot be built.
        guard (try? renderer.pipeline(for: original)) != nil else {
            log.error("original \(original.slug, privacy: .public) has no pipeline on this GPU")
            return nil
        }
        self.original = original
        self.itemID = original.id
        self.renderer = renderer
        self.settings = settings
        self.location = location
        // Start somewhere different each time, so two displays don't mirror each other.
        motionTime = Double.random(in: 0..<600)
        layer = metalLayer
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = OriginalRenderer.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 2
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.contentsGravity = .resize
        metalLayer.backgroundColor = CGColor(gray: 0.08, alpha: 1)
    }

    func update(settings: PlaybackSettings) {
        self.settings = settings
    }

    func resize(to size: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = CGRect(origin: .zero, size: size)
        metalLayer.contentsScale = scale
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        pixelSize = (width, height)
        let drawable = KinoraOriginals.drawableSize(for: original, width: width, height: height)
        metalLayer.drawableSize = CGSize(width: drawable.width, height: drawable.height)
        CATransaction.commit()
        // Never show an empty layer: draw a frame straight away.
        draw()
    }

    func apply(_ decision: PlaybackDecision) {
        switch decision {
        case .play(let cap):
            let rate = KinoraOriginals.framesPerSecond(for: original, settings: settings, cap: cap)
            guard timer == nil || rate != framesPerSecond else { return }
            framesPerSecond = rate
            timer?.invalidate()
            if runStarted == nil { runStarted = CACurrentMediaTime() }
            let interval = 1 / Double(rate)
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.draw() }
            }
            timer?.tolerance = interval * 0.2
        case .pause:
            guard let timer else { return }
            timer.invalidate()
            self.timer = nil
            if let runStarted { motionTime += CACurrentMediaTime() - runStarted }
            runStarted = nil
            // One last frame at the exact moment, so the still matches the clock.
            draw()
        }
    }

    func snapshot(width: Int, height: Int) async -> IOSurfaceRef? {
        try? renderer.surface(original, width: width, height: height, time: currentTime, sky: sky)
    }

    func tearDown() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Drawing

    private var currentTime: Double {
        motionTime + (runStarted.map { CACurrentMediaTime() - $0 } ?? 0)
    }

    private var sky: SkySample {
        original.usesSun ? SkySample.at(Date(), location: location) : .afternoon
    }

    private func draw() {
        // Skip a frame rather than wait when the GPU is still busy with earlier ones: waiting
        // for a drawable would stall WallpaperAgent's calls on the main thread.
        let asked = CACurrentMediaTime()
        guard asked >= backOffUntil, inFlight.begin() else { return }
        let drawable = metalLayer.nextDrawable()
        if CACurrentMediaTime() - asked > 0.2 {
            backOffUntil = CACurrentMediaTime() + 5
            log.notice("original \(self.original.slug, privacy: .public) waited for a drawable; backing off for 5 s")
        }
        guard let drawable, let commands = renderer.queue.makeCommandBuffer() else {
            inFlight.end()
            return
        }
        let size = (Int(metalLayer.drawableSize.width), Int(metalLayer.drawableSize.height))
        let uniforms = OriginalRenderer.uniforms(for: original, width: size.0, height: size.1, time: currentTime, sky: sky)
        do {
            try renderer.encode(original, uniforms: uniforms, into: drawable.texture, commandBuffer: commands)
        } catch {
            inFlight.end()
            log.error("original \(self.original.slug, privacy: .public) failed to draw: \(String(describing: error), privacy: .public)")
            return
        }
        let flight = inFlight
        commands.addCompletedHandler { _ in flight.end() }
        commands.present(drawable)
        commands.commit()
    }
}

/// Frames the GPU has not finished yet, at most two. Ended from Metal's completion thread.
private final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func begin() -> Bool {
        lock.withLock {
            guard count < 2 else { return false }
            count += 1
            return true
        }
    }

    func end() { lock.withLock { count = max(0, count - 1) } }
}
