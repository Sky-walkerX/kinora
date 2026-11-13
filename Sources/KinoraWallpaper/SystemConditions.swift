// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import KinoraKit

/// The Mac's state that playback decisions depend on: power source, Low Power Mode, thermal
/// pressure, and how much of each display's desktop windows hide. It calls `onChange` when
/// something changed that could change a decision.
@MainActor final class SystemConditions {
    private(set) var onBattery = false
    private(set) var lowPowerMode = false
    private(set) var thermal: ThermalLevel = .nominal
    /// Reduce Motion in Accessibility settings.
    private(set) var reduceMotion = false
    private var coverage: [CGDirectDisplayID: Double] = [:]
    private var coverageTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    var onChange: () -> Void = {}

    /// How often to look at the window list while a desktop surface is showing. The check costs
    /// well under a millisecond.
    static let coverageInterval: TimeInterval = 2

    func start() {
        refreshPower()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPower() }
            })
        }
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibility() }
        })
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let conditions = Unmanaged<SystemConditions>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { conditions.refreshPower() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    /// Watches window coverage only while some surface is on the desktop.
    func watchCoverage(_ needed: Bool) {
        if needed, coverageTimer == nil {
            refreshCoverage()
            coverageTimer = Timer.scheduledTimer(withTimeInterval: Self.coverageInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCoverage() }
            }
            coverageTimer?.tolerance = 0.5
        } else if !needed, let timer = coverageTimer {
            timer.invalidate()
            coverageTimer = nil
            coverage.removeAll()
        }
    }

    /// The fraction of `display`'s desktop hidden by windows; the main display when nil.
    func coverage(of display: UInt32?) -> Double {
        coverage[display ?? CGMainDisplayID()] ?? 0
    }

    // MARK: - Refresh

    private func refreshPower() {
        let battery = Self.isOnBattery()
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let level: ThermalLevel = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        guard battery != onBattery || lowPower != lowPowerMode || level != thermal else { return }
        (onBattery, lowPowerMode, thermal) = (battery, lowPower, level)
        onChange()
    }

    private func refreshAccessibility() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard reduce != reduceMotion else { return }
        reduceMotion = reduce
        onChange()
    }

    private func refreshCoverage() {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let rects = DesktopCoverage.occludingRects(from: windows)
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(displays.count), &displays, &count)
        var fresh: [CGDirectDisplayID: Double] = [:]
        for display in displays.prefix(Int(count)) {
            fresh[display] = DesktopCoverage.coveredFraction(of: CGDisplayBounds(display), by: rects)
        }
        // Small changes, such as a window nudged a few points, do not change any decision.
        let changed = fresh.keys != coverage.keys || fresh.contains { abs($0.value - (coverage[$0.key] ?? 0)) > 0.01 }
        coverage = fresh
        if changed { onChange() }
    }

    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPMBatteryPowerKey
    }
}
