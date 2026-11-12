// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// The user's playback rules. The app writes them to the library's settings file; the plug-in
/// reads them. Missing keys fall back to the defaults, so older files keep working.
public struct PlaybackSettings: Codable, Equatable, Sendable {
    /// Pause when windows hide at least `coveredThreshold` of a display's desktop.
    public var pauseWhenCovered = true
    public var coveredThreshold = 0.95
    /// Frame rate cap on battery power; nil plays at the video's own rate.
    public var batteryFrameCap: Int? = 30
    public var pauseInLowPowerMode = true
    /// Pause at thermal state "serious" or worse.
    public var pauseWhenHot = true
    /// Battery-first, the default: the desktop "rests while you work". It plays on the Lock
    /// Screen, for `settleDelay` seconds after unlock or after a wallpaper is picked, and whenever
    /// the desktop is clear of windows; otherwise it holds a still frame, like Apple's aerials.
    public var settleAfterUnlock = true
    public var settleDelay: TimeInterval = 5
    /// At or below this coverage the desktop counts as clear, and a resting wallpaper moves.
    public var clearDesktopThreshold = 0.05

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlaybackSettings()
        pauseWhenCovered = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenCovered) ?? d.pauseWhenCovered
        coveredThreshold = min(1, max(0.5, try c.decodeIfPresent(Double.self, forKey: .coveredThreshold) ?? d.coveredThreshold))
        batteryFrameCap = c.contains(.batteryFrameCap) ? try c.decodeIfPresent(Int.self, forKey: .batteryFrameCap) : d.batteryFrameCap
        pauseInLowPowerMode = try c.decodeIfPresent(Bool.self, forKey: .pauseInLowPowerMode) ?? d.pauseInLowPowerMode
        pauseWhenHot = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenHot) ?? d.pauseWhenHot
        settleAfterUnlock = try c.decodeIfPresent(Bool.self, forKey: .settleAfterUnlock) ?? d.settleAfterUnlock
        settleDelay = max(0, try c.decodeIfPresent(Double.self, forKey: .settleDelay) ?? d.settleDelay)
        clearDesktopThreshold = min(0.5, max(0, try c.decodeIfPresent(Double.self, forKey: .clearDesktopThreshold) ?? d.clearDesktopThreshold))
    }
}

public enum ThermalLevel: Int, Comparable, Sendable {
    case nominal, fair, serious, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Everything a playback decision depends on, for one surface.
public struct PlaybackConditions: Equatable, Sendable {
    public var presentation: PresentationMode = .default
    public var activity: ActivityState = .active
    public var isPreview = false
    /// Fraction of this display's desktop hidden by windows, 0...1.
    public var desktopCoverage = 0.0
    public var onBattery = false
    public var lowPowerMode = false
    public var thermal: ThermalLevel = .nominal
    /// Seconds since the Mac last unlocked; nil when it has not been locked since the surface started.
    public var secondsSinceUnlock: TimeInterval?

    public init() {}
}

public enum PauseReason: String, Equatable, Sendable {
    case suspendedBySystem, lowPowerMode, hot, covered, settled
}

public enum PlaybackDecision: Equatable, Sendable {
    /// Play, at most at `maxFramesPerSecond` when set.
    case play(maxFramesPerSecond: Int?)
    case pause(PauseReason)
}

public enum PlaybackPolicy {
    public static func decide(_ c: PlaybackConditions, settings: PlaybackSettings) -> PlaybackDecision {
        if c.activity == .suspended { return .pause(.suspendedBySystem) }
        // System Settings' preview always animates: it is small and the user is looking at it.
        if c.isPreview { return .play(maxFramesPerSecond: nil) }
        if settings.pauseInLowPowerMode, c.lowPowerMode { return .pause(.lowPowerMode) }
        if settings.pauseWhenHot, c.thermal >= .serious { return .pause(.hot) }
        let cap = c.onBattery ? settings.batteryFrameCap : nil
        // The Lock Screen and the screen saver fill the display; windows do not cover them.
        if c.presentation != .default { return .play(maxFramesPerSecond: cap) }
        if settings.pauseWhenCovered, c.desktopCoverage >= settings.coveredThreshold { return .pause(.covered) }
        if settings.settleAfterUnlock, (c.secondsSinceUnlock ?? .infinity) >= settings.settleDelay,
           c.desktopCoverage > settings.clearDesktopThreshold { return .pause(.settled) }
        return .play(maxFramesPerSecond: cap)
    }
}
