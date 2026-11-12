// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import Foundation
import Testing
@testable import KinoraKit

@Suite struct PlaybackPolicyTests {
    let defaults = PlaybackSettings()

    func decide(_ change: (inout PlaybackConditions) -> Void, settings: PlaybackSettings = PlaybackSettings()) -> PlaybackDecision {
        var c = PlaybackConditions()
        change(&c)
        return PlaybackPolicy.decide(c, settings: settings)
    }

    @Test func playsAVisibleDesktopAtFullRate() {
        #expect(decide { $0.desktopCoverage = 0.4 } == .play(maxFramesPerSecond: nil))
    }

    @Test func pausesWhenWindowsHideTheDesktop() {
        #expect(decide { $0.desktopCoverage = 0.95 } == .pause(.covered))
        #expect(decide { $0.desktopCoverage = 0.94 } == .play(maxFramesPerSecond: nil))
    }

    @Test func coverageDoesNotMatterOnTheLockScreen() {
        #expect(decide { $0.presentation = .locked; $0.desktopCoverage = 1 } == .play(maxFramesPerSecond: nil))
        #expect(decide { $0.presentation = .idle; $0.desktopCoverage = 1 } == .play(maxFramesPerSecond: nil))
    }

    @Test func capsTheFrameRateOnBattery() {
        #expect(decide { $0.onBattery = true } == .play(maxFramesPerSecond: 30))
        #expect(decide { $0.onBattery = true; $0.presentation = .locked } == .play(maxFramesPerSecond: 30))
        var uncapped = PlaybackSettings(); uncapped.batteryFrameCap = nil
        #expect(decide({ $0.onBattery = true }, settings: uncapped) == .play(maxFramesPerSecond: nil))
    }

    @Test func pausesInLowPowerModeAndWhenHotEvenWhenLocked() {
        #expect(decide { $0.lowPowerMode = true; $0.presentation = .locked } == .pause(.lowPowerMode))
        #expect(decide { $0.thermal = .serious } == .pause(.hot))
        #expect(decide { $0.thermal = .fair } == .play(maxFramesPerSecond: nil))
    }

    @Test func theSystemsSuspensionWinsOverEverything() {
        #expect(decide { $0.activity = .suspended; $0.isPreview = true } == .pause(.suspendedBySystem))
    }

    @Test func previewsAlwaysAnimate() {
        #expect(decide { $0.isPreview = true; $0.lowPowerMode = true; $0.desktopCoverage = 1 } == .play(maxFramesPerSecond: nil))
    }

    @Test func appleStyleSettlesAfterUnlock() {
        var apple = PlaybackSettings(); apple.settleAfterUnlock = true
        #expect(decide({ $0.secondsSinceUnlock = 2 }, settings: apple) == .play(maxFramesPerSecond: nil))
        #expect(decide({ $0.secondsSinceUnlock = 5 }, settings: apple) == .pause(.settled))
        #expect(decide({ $0.secondsSinceUnlock = nil }, settings: apple) == .pause(.settled))
        #expect(decide({ $0.presentation = .locked }, settings: apple) == .play(maxFramesPerSecond: nil))
    }

    @Test func respectsSwitchedOffRules() {
        var lenient = PlaybackSettings()
        lenient.pauseWhenCovered = false; lenient.pauseInLowPowerMode = false; lenient.pauseWhenHot = false
        #expect(decide({ $0.desktopCoverage = 1; $0.lowPowerMode = true; $0.thermal = .critical }, settings: lenient) == .play(maxFramesPerSecond: nil))
    }

    @Test func settingsDecodeWithDefaultsAndClamps() throws {
        let partial = try JSONDecoder().decode(PlaybackSettings.self, from: Data(#"{"coveredThreshold": 0.2, "batteryFrameCap": null}"#.utf8))
        #expect(partial.coveredThreshold == 0.5)
        #expect(partial.batteryFrameCap == nil)
        #expect(partial.pauseInLowPowerMode)
        let empty = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        #expect(empty == PlaybackSettings())
    }
}

@Suite struct DesktopCoverageTests {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 500)

    @Test func noWindowsCoverNothing() {
        #expect(DesktopCoverage.coveredFraction(of: display, by: []) == 0)
    }

    @Test func aFullScreenWindowCoversEverything() {
        #expect(DesktopCoverage.coveredFraction(of: display, by: [display]) == 1)
    }

    @Test func overlappingWindowsCountOnce() {
        let a = CGRect(x: 0, y: 0, width: 600, height: 500), b = CGRect(x: 400, y: 0, width: 600, height: 500)
        #expect(DesktopCoverage.coveredFraction(of: display, by: [a, b]) == 1)
        let c = CGRect(x: 0, y: 0, width: 500, height: 250)
        #expect(DesktopCoverage.coveredFraction(of: display, by: [c, c]) == 0.25)
    }

    @Test func windowsOnOtherDisplaysAreClipped() {
        let other = CGRect(x: 1000, y: 0, width: 800, height: 500)
        let half = CGRect(x: 500, y: 0, width: 1000, height: 500)
        #expect(DesktopCoverage.coveredFraction(of: display, by: [other]) == 0)
        #expect(DesktopCoverage.coveredFraction(of: display, by: [half]) == 0.5)
    }

    @Test func aGapBetweenWindowsStaysUncovered() {
        let top = CGRect(x: 0, y: 0, width: 1000, height: 200), bottom = CGRect(x: 0, y: 300, width: 1000, height: 200)
        #expect(abs(DesktopCoverage.coveredFraction(of: display, by: [top, bottom]) - 0.8) < 1e-9)
    }

    @Test func picksOrdinaryVisibleWindowsFromTheWindowList() {
        func window(layer: Int, alpha: Double, _ rect: CGRect) -> [String: Any] {
            [kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary]
        }
        let rects = DesktopCoverage.occludingRects(from: [
            window(layer: 0, alpha: 1, CGRect(x: 0, y: 0, width: 10, height: 10)),
            window(layer: 25, alpha: 1, CGRect(x: 0, y: 0, width: 1470, height: 33)), // menu bar level
            window(layer: 0, alpha: 0, CGRect(x: 5, y: 5, width: 10, height: 10)),
        ])
        #expect(rects == [CGRect(x: 0, y: 0, width: 10, height: 10)])
    }
}
