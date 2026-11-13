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
    /// Kinora's live selection, which choices made with "Use as Wallpaper" follow.
    private(set) var selection: KinoraSelection?
    /// True when macOS's current choice follows the live selection, so changes apply without a restart.
    private(set) var followsSelection = false
    /// True when another app or System Settings replaced Kinora. Kinora does not fight it.
    private(set) var replacedByOther = false
    private(set) var canRestore = false
    private(set) var working = false
    var lastError: String?

    private let store = WallpaperStoreFiles.current()
    private let location = LibraryLocation.current
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?

    /// Refreshes whenever anything writes the wallpaper store: System Settings, another app,
    /// or Kinora itself. Writers either replace the file atomically, which changes the folder,
    /// or rewrite it in place, which changes only the file, so both are watched.
    func watchStore() {
        guard folderWatcher == nil else { return }
        folderWatcher = watch(store.storeFolder, events: [.write, .rename, .delete])
        armFileWatcher()
    }

    private func armFileWatcher() {
        fileWatcher?.cancel()
        // An atomic replacement leaves this watcher on the old file, so it is re-armed every time.
        fileWatcher = store.primaryFile.flatMap { watch($0, events: [.write, .extend, .rename, .delete, .attrib]) }
    }

    private func watch(_ url: URL, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleRefresh() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// Writers touch the store several times per change; refresh once it settles.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.armFileWatcher()
            }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func refresh() {
        plugIn = PlugInRegistration.state()
        canRestore = store.hasOriginalBackup
        selection = (try? Data(contentsOf: location.selection)).flatMap(KinoraSelection.decode)
        guard let current = try? store.readPrimary() else { return }
        let configuration = ChoiceConfiguration.decode(WallpaperStoreEditor.kinoraConfiguration(current))
        let isKinora = WallpaperStoreEditor.kinoraIsSelected(current)
        followsSelection = isKinora && configuration?.follows == true
        currentItem = isKinora ? configuration?.rules(selection: selection).wallpaper : nil
        replacedByOther = currentItem == nil && canRestore
    }

    /// Re-enables or re-registers the plug-in when macOS left it off. Run at every launch.
    func repairPlugIn() async {
        plugIn = await Task.detached { PlugInRegistration.repair() }.value
    }

    func use(_ item: LibraryItem) async {
        await use(itemID: item.id)
    }

    func use(itemID: UUID) async {
        // A new wallpaper keeps the Lock Screen and dark variants but ends any rotation or schedule.
        var rules = selection?.rules ?? WallpaperRules(wallpaper: itemID)
        rules.wallpaper = itemID
        rules.rotation = nil
        rules.schedule = nil
        await apply(rules)
    }

    /// The rules to edit: the live selection when there is one, else a fresh one around `fallback`.
    func editableRules(fallback: UUID) -> WallpaperRules {
        selection?.rules ?? WallpaperRules(wallpaper: fallback)
    }

    /// Plays a playlist on the desktop, changing every `interval` seconds (zero: on every unlock).
    func play(_ playlist: Playlist, every interval: TimeInterval, shuffle: Bool) async {
        guard let first = playlist.items.first else { return }
        var rules = editableRules(fallback: first)
        rules.schedule = nil
        rules.wallpaper = first
        rules.rotation = WallpaperRules.Rotation(items: playlist.items, interval: interval, since: Date(), playlist: playlist.id, shuffle: shuffle)
        await apply(rules)
    }

    /// Keeps a playing rotation in step with its playlist after the playlist changed.
    func playlistChanged(_ playlist: Playlist) async {
        guard var rules = selection?.rules, var rotation = rules.rotation, rotation.playlist == playlist.id,
              rotation.items != playlist.items else { return }
        if playlist.items.isEmpty {
            rules.rotation = nil
        } else {
            rotation.items = playlist.items
            rules.rotation = rotation
            if !playlist.items.contains(rules.wallpaper), let first = playlist.items.first { rules.wallpaper = first }
        }
        await apply(rules)
    }

    /// Moves a rotation on to its next wallpaper.
    func next() async {
        guard let rules = selection?.rules, rules.rotation != nil else { return }
        await apply(rules.advanced())
    }

    /// Sets the time-of-day schedule; an empty list turns it off.
    func setSchedule(_ entries: [WallpaperRules.ScheduleEntry], fallback: UUID) async {
        await apply(editableRules(fallback: fallback).scheduled(entries))
    }

    /// Where Kinora's rules use an item.
    func uses(of id: UUID) -> [RuleUse] {
        selection?.rules.uses(of: id) ?? []
    }

    /// Takes an item out of the live selection before it leaves the library. Returns false when
    /// it is the only thing Kinora shows, so removing it would leave the wallpaper empty.
    func forget(_ id: UUID, replacement: UUID?) async -> Bool {
        guard let rules = selection?.rules, !rules.uses(of: id).isEmpty else { return true }
        guard let edited = rules.removing(id, replacement: replacement) else { return !followsSelection }
        await apply(edited)
        return true
    }

    /// The item on the desktop right now, after rotation, schedule and dark mode.
    func shownItem(dark: Bool, at date: Date = Date()) -> UUID? {
        guard let currentItem else { return nil }
        guard followsSelection, let rules = selection?.rules else { return currentItem }
        return rules.item(for: .default, appearance: dark ? .dark : .light, at: date)
    }

    /// Changes the live selection. When macOS's choice already follows Kinora, the plug-in picks
    /// it up at once; otherwise Kinora becomes the wallpaper, which restarts WallpaperAgent once.
    func apply(_ rules: WallpaperRules) async {
        working = true
        defer { working = false }
        do {
            try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
            try KinoraSelection(rules: rules).encoded().write(to: location.selection, options: .atomic)
            LibraryModel.postLibraryChanged()
            if !followsSelection {
                if plugIn != .enabled { await repairPlugIn() }
                guard plugIn == .enabled else {
                    lastError = "macOS has Kinora's wallpaper plug-in switched off, so it can't show wallpapers yet."
                    return
                }
                let configuration = ChoiceConfiguration(wallpaper: rules.wallpaper, followsKinora: true).encoded()
                try store.apply { WallpaperStoreEditor.selectingKinora($0, configuration: configuration, now: Date()) }
                await WallpaperAgentControl.reload()
            }
        } catch {
            lastError = Self.describe(error)
        }
        refresh()
    }

    /// Edits the live selection's rules in place, for variants and rotations.
    func change(_ edit: (inout WallpaperRules) -> Void) async {
        guard var rules = selection?.rules else { return }
        edit(&rules)
        await apply(rules)
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
