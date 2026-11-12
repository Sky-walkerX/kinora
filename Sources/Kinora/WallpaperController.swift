// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import KinoraKit
import Observation

/// Puts Kinora on the desktop and Lock Screen, keeps the plug-in switched on, and puts the
/// user's own wallpaper back on request.
@MainActor @Observable final class WallpaperController {
    enum PlugInState: Equatable {
        case unknown, enabled, disabled, missing
    }

    private(set) var plugIn: PlugInState = .unknown
    /// The library item Kinora shows on the desktop, when Kinora is the current wallpaper.
    private(set) var currentItem: UUID?
    /// True when another app or System Settings replaced Kinora. Kinora does not fight it.
    private(set) var replacedByOther = false
    private(set) var canRestore = false
    private(set) var working = false
    var lastError: String?

    private let store = WallpaperStoreFiles.current()

    func refresh() {
        plugIn = PlugInRegistration.state()
        canRestore = store.hasOriginalBackup
        guard let current = try? store.readPrimary() else { return }
        let configuration = ChoiceConfiguration.decode(WallpaperStoreEditor.kinoraConfiguration(current))
        currentItem = WallpaperStoreEditor.kinoraIsSelected(current) ? configuration?.wallpaper : nil
        replacedByOther = currentItem == nil && canRestore
    }

    /// Re-enables or re-registers the plug-in when macOS left it off. Run at every launch.
    func repairPlugIn() async {
        plugIn = await Task.detached { PlugInRegistration.repair() }.value
    }

    func use(_ item: LibraryItem) async {
        working = true
        defer { working = false }
        if plugIn != .enabled { await repairPlugIn() }
        guard plugIn == .enabled else {
            lastError = "macOS has Kinora's wallpaper plug-in switched off, so it can't show wallpapers yet."
            return
        }
        let configuration = ChoiceConfiguration(wallpaper: item.id).encoded()
        do {
            try store.apply { WallpaperStoreEditor.selectingKinora($0, configuration: configuration, now: Date()) }
            await WallpaperAgentControl.reload()
        } catch {
            lastError = Self.describe(error)
        }
        refresh()
    }

    func restoreOriginal() async {
        working = true
        defer { working = false }
        do {
            if try store.restoreOriginal() { await WallpaperAgentControl.reload() }
        } catch {
            lastError = Self.describe(error)
        }
        refresh()
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case WallpaperStoreError.noStore:
            "macOS hasn't created its wallpaper settings yet. Pick any wallpaper in System Settings once, then try again."
        case WallpaperStoreError.unreadable(let name):
            "Kinora couldn't read macOS's wallpaper settings (\(name)), so it changed nothing."
        case WallpaperStoreError.validationFailed(let name):
            "Writing macOS's wallpaper settings (\(name)) didn't check out. Use Restore Original Wallpaper to undo."
        default:
            error.localizedDescription
        }
    }
}

/// WallpaperAgent draws every wallpaper. It reads its store at launch.
enum WallpaperAgentControl {
    /// Restarts WallpaperAgent so it reads the store again. Every display blinks once.
    static func reload() async {
        await Task.detached { _ = Shell.run("/usr/bin/killall", ["WallpaperAgent"]) }.value
    }
}

/// The plug-in's registration with macOS. LaunchServices registers it when Kinora first runs,
/// but macOS can leave it switched off, which silently stops it drawing.
enum PlugInRegistration {
    static func state() -> WallpaperController.PlugInState {
        let output = Shell.run("/usr/bin/pluginkit", ["-m", "-i", KinoraIdentity.wallpaperBundleID]).output
        guard let line = output.split(separator: "\n").first(where: { $0.contains(KinoraIdentity.wallpaperBundleID) }) else {
            return .missing
        }
        // pluginkit marks a plug-in switched on with "+" and one switched off with "-". With no
        // mark macOS has not decided, and WallpaperAgent will not use it, so that counts as off.
        return line.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? .enabled : .disabled
    }

    static func repair() -> WallpaperController.PlugInState {
        if state() == .missing, let appex = Bundle.main.builtInPlugInsURL?.deletingLastPathComponent()
            .appendingPathComponent("Extensions/KinoraWallpaper.appex") {
            _ = Shell.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                          ["-f", Bundle.main.bundlePath])
            _ = Shell.run("/usr/bin/pluginkit", ["-a", appex.path])
        }
        if state() != .enabled { _ = Shell.run("/usr/bin/pluginkit", ["-e", "use", "-i", KinoraIdentity.wallpaperBundleID]) }
        return state()
    }
}

enum Shell {
    struct Result { var status: Int32; var output: String }

    static func run(_ tool: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return Result(status: -1, output: "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
