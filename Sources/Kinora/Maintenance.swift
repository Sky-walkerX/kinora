// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import AppKit
import Foundation
import KinoraKit
import KinoraRender
import UniformTypeIdentifiers

/// A plain-text report for bug reports. It holds versions, states and counts, never file
/// names, wallpaper names or paths in the user's home, and it is only saved where the user
/// chooses; Kinora never sends it anywhere.
@MainActor enum Diagnostics {
    static func report(models: AppModels = .shared) async -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines: [String] = []
        func add(_ key: String, _ value: Any) { lines.append("\(key): \(value)") }
        lines.append("Kinora diagnostics, \(Date().formatted(.iso8601))")
        add("Kinora", "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))")
        add("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        add("Model", Self.sysctl("hw.model") ?? "?")
        add("Architecture", Self.sysctl("hw.machine") ?? "?")
        add("Displays", NSScreen.screens.map { "\(Int($0.frame.width * $0.backingScaleFactor))x\(Int($0.frame.height * $0.backingScaleFactor))" }.joined(separator: ", "))
        add("Metal", OriginalRenderer.shared?.device.name ?? "unavailable")

        let wallpaper = models.wallpaper
        wallpaper.refresh()
        add("Plug-in", String(describing: wallpaper.plugIn))
        add("Kinora is the wallpaper", wallpaper.currentItem != nil)
        add("Follows Kinora's selection", wallpaper.followsSelection)
        add("Replaced by another wallpaper", wallpaper.replacedByOther)
        add("Original wallpaper backed up", wallpaper.canRestore)
        if let store = try? WallpaperStoreFiles.current().readPrimary() {
            let providers = WallpaperStoreEditor.desktopProviders(store)
            add("Store desktop providers", providers.map { $0 == KinoraIdentity.providerID ? "kinora" : $0 }.joined(separator: ", "))
        } else {
            add("Store", "unreadable or missing")
        }
        if let rules = wallpaper.selection?.rules {
            add("Rules", "lock screen \(rules.lockScreen != nil), dark \(rules.dark != nil), rotation \(rules.rotation?.items.count ?? 0) items every \(Int(rules.rotation?.interval ?? 0)) s, schedule \(rules.schedule?.count ?? 0) entries")
        }

        let library = models.library
        var kinds: [String: Int] = [:]
        for item in library.items { kinds[item.kind.rawValue, default: 0] += 1 }
        add("Library", kinds.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ").ifEmpty("empty"))
        add("Playlists", library.playlists.count)
        add("Disk saved by conversion", library.savedBytes.formatted(.byteCount(style: .file)))
        let settings = models.settings.playback
        add("Settings", "rest while working \(settings.settleAfterUnlock), pause covered \(settings.pauseWhenCovered), battery cap \(settings.batteryFrameCap.map(String.init) ?? "none"), low power pause \(settings.pauseInLowPowerMode), hot pause \(settings.pauseWhenHot), reduce motion \(settings.pauseWithReduceMotion), paused \(settings.paused)")
        if let reading = models.energy.reading {
            add("Plug-in now", String(format: "%.1f%% CPU, %@ mW", reading.cpuPercent, reading.milliwatts.map { String(format: "%.0f", $0) } ?? "?"))
        }
        lines.append("")
        lines.append("Recent plug-in and app log (last 30 minutes):")
        let log = await Task.detached {
            Shell.run("/usr/bin/log", ["show", "--last", "30m", "--style", "compact", "--predicate", "subsystem == \"io.github.sky-walkerx.kinora\""]).output
        }.value
        lines.append(contentsOf: log.split(separator: "\n").suffix(300).map(String.init))
        return lines.joined(separator: "\n")
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Asks where to save the report, then saves it.
    static func export() async {
        let text = await report()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Kinora Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// Removes Kinora from macOS, leaving no trace in System Settings: puts back the wallpaper the
/// user had (when Kinora is still showing), switches off and unregisters the plug-in, and,
/// if asked, deletes the library. The user then drags the app to the Bin.
@MainActor enum Uninstaller {
    struct Outcome {
        var restoredWallpaper: Bool
        var unregistered: Bool
        var deletedLibrary: Bool
    }

    static func run(deleteLibrary: Bool, models: AppModels = .shared) async -> Outcome {
        let wallpaper = models.wallpaper
        wallpaper.refresh()
        var outcome = Outcome(restoredWallpaper: false, unregistered: false, deletedLibrary: false)
        // Only when Kinora is still the wallpaper: a later choice by the user stays.
        if wallpaper.currentItem != nil, wallpaper.canRestore {
            await wallpaper.restoreOriginal()
            outcome.restoredWallpaper = true
        }
        let appex = Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions/KinoraWallpaper.appex").path
        let bundle = Bundle.main.bundlePath
        outcome.unregistered = await Task.detached { () -> Bool in
            _ = Shell.run("/usr/bin/pluginkit", ["-e", "ignore", "-i", KinoraIdentity.wallpaperBundleID])
            _ = Shell.run("/usr/bin/pluginkit", ["-r", appex])
            _ = Shell.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-u", bundle])
            // WallpaperAgent drops the plug-in's section from System Settings when it restarts.
            _ = Shell.run("/usr/bin/killall", ["WallpaperAgent"])
            return !Shell.run("/usr/bin/pluginkit", ["-m", "-i", KinoraIdentity.wallpaperBundleID]).output.contains(KinoraIdentity.wallpaperBundleID)
        }.value
        if deleteLibrary {
            outcome.deletedLibrary = (try? FileManager.default.removeItem(at: models.library.location.root)) != nil
            if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        }
        return outcome
    }
}
