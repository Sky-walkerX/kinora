// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import KinoraKit
import KinoraRender
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
    /// The live selection's rules while macOS shows them. Nil while another wallpaper is showing:
    /// `selection.json` then only remembers what Kinora showed last, and nothing should act on it
    /// as if it were on screen.
    var liveRules: WallpaperRules? { followsSelection ? selection?.rules : nil }
    /// The last time-of-day schedule Kinora replaced, so the schedule editor can bring it back.
    private(set) var previousSchedule: [WallpaperRules.ScheduleEntry]? = WallpaperController.loadPreviousSchedule()
    /// True when another app or System Settings replaced Kinora. Kinora does not fight it.
    private(set) var replacedByOther = false
    private(set) var canRestore = false
    private(set) var working = false
    var lastError: String?

    /// The choice macOS shows, when it is Kinora's.
    private(set) var configuration: ChoiceConfiguration?
    /// Moves on whenever the rules change what is shown by themselves (a schedule boundary or a
    /// rotation step), so views that say what is on screen redraw then.
    private var clock = Date()
    private var clockTimer: Timer?
    /// The library, for working out what the plug-in falls back to when an item is gone.
    weak var library: LibraryModel?

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
        self.configuration = isKinora ? configuration : nil
        followsSelection = isKinora && configuration?.follows == true
        currentItem = isKinora ? configuration?.rules(selection: selection).wallpaper : nil
        replacedByOther = currentItem == nil && canRestore
        armClock()
    }

    /// Wakes the views at the next change the rules make by themselves.
    private func armClock() {
        clockTimer?.invalidate()
        clockTimer = nil
        guard currentItem != nil, let rules = configuration?.rules(selection: selection),
              let next = rules.nextChange(after: Date()) else { return }
        clockTimer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow + 0.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clock = Date()
                self?.armClock()
            }
        }
    }

    /// Re-enables or re-registers the plug-in when macOS left it off. Run at every launch.
    func repairPlugIn() async {
        plugIn = await Task.detached { PlugInRegistration.repair() }.value
    }

    func use(_ item: LibraryItem) async {
        await use(itemID: item.id)
    }

    func use(itemID: UUID) async {
        // A new wallpaper keeps the Lock Screen and dark variants but ends any rotation or schedule
        // (the schedule editor can bring the schedule back).
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
    /// When it is already playing, the new pace or order starts from the wallpaper on screen.
    func play(_ playlist: Playlist, every interval: TimeInterval, shuffle: Bool) async {
        guard let first = playlist.items.first else { return }
        var rules = editableRules(fallback: first)
        rules.schedule = nil
        if let playing = liveRules?.rotation, playing.playlist == playlist.id {
            rules.rotation = playing.changing(items: playlist.items, shuffle: shuffle, interval: interval, at: Date())
        } else {
            rules.wallpaper = first
            rules.rotation = WallpaperRules.Rotation(items: playlist.items, interval: interval, since: Date(), playlist: playlist.id, shuffle: shuffle)
        }
        await apply(rules)
    }

    /// The playlist's rotation, when it is the one on the desktop.
    func playingRotation(of playlistID: UUID) -> WallpaperRules.Rotation? {
        liveRules?.rotation.flatMap { $0.playlist == playlistID ? $0 : nil }
    }

    /// Shuffles or unshuffles a playlist that is playing, keeping the wallpaper on screen.
    func setShuffle(_ shuffle: Bool, playlist playlistID: UUID) async {
        guard var rules = liveRules, let rotation = rules.rotation, rotation.playlist == playlistID,
              (rotation.shuffle == true) != shuffle else { return }
        rules.rotation = rotation.changing(shuffle: shuffle, at: Date())
        await apply(rules)
    }

    /// Keeps a playing rotation in step with its playlist after the playlist changed, keeping the
    /// wallpaper on screen where it can. While another wallpaper is showing, Kinora's remembered
    /// rules are updated quietly and the desktop is left alone.
    func playlistChanged(_ playlist: Playlist) async {
        guard var rules = selection?.rules, let rotation = rules.rotation, rotation.playlist == playlist.id,
              rotation.items != playlist.items else { return }
        if playlist.items.isEmpty {
            rules.rotation = nil
        } else {
            rules.rotation = rotation.replacingItems(playlist.items, at: Date())
            if !playlist.items.contains(rules.wallpaper), let first = playlist.items.first { rules.wallpaper = first }
        }
        await apply(rules, activating: false)
    }

    /// Moves a rotation on to its next wallpaper. Only while Kinora is the wallpaper.
    func next() async {
        guard let rules = liveRules, rules.rotation != nil else { return }
        await apply(rules.advanced())
    }

    /// Sets the time-of-day schedule; an empty list turns it off.
    func setSchedule(_ entries: [WallpaperRules.ScheduleEntry], fallback: UUID) async {
        await apply(editableRules(fallback: fallback).scheduled(entries))
    }

    /// Where Kinora's rules on screen use an item.
    func uses(of id: UUID) -> [RuleUse] {
        liveRules?.uses(of: id) ?? []
    }

    /// Takes an item out of the live selection before it leaves the library. Returns false when
    /// it is the only thing Kinora shows, so removing it would leave the wallpaper empty. While
    /// another wallpaper is showing, the remembered rules are tidied without touching the desktop.
    func forget(_ id: UUID, replacement: UUID?) async -> Bool {
        guard let rules = selection?.rules, !rules.uses(of: id).isEmpty else { return true }
        guard let edited = rules.removing(id, replacement: replacement, at: Date()) else { return !followsSelection }
        await apply(edited, activating: false)
        return true
    }

    /// What a surface shows right now, worked out exactly as the plug-in works it out: rotation,
    /// schedule, Dark Mode and the Lock Screen, then the plug-in's fallbacks for removed items.
    /// Nil when Kinora is not the wallpaper.
    func shown(_ mode: PresentationMode = .default, dark: Bool, at date: Date? = nil) -> SurfaceResolution? {
        guard currentItem != nil else { return nil }
        let now = max(clock, date ?? Date())
        // Only the plug-in counts unlocks; the app works out the rest.
        return SurfaceResolution.resolve(configuration: configuration, selection: selection, mode: mode,
                                         appearance: dark ? .dark : .light, at: now, unlockCount: 0,
                                         library: library.map { location.showableItemIDs($0.items) } ?? [],
                                         originalsAvailable: OriginalRenderer.shared != nil)
    }

    /// The item on the desktop right now. Nil when Kinora is not the wallpaper, or when a rotation
    /// steps on each unlock, which only the plug-in can count.
    func shownItem(dark: Bool, at date: Date? = nil) -> UUID? {
        guard let resolution = shown(dark: dark, at: date), !resolution.dependsOnUnlocks else { return nil }
        return resolution.shown
    }

    /// Changes the live selection. When macOS's choice already follows Kinora, the plug-in picks
    /// it up at once; otherwise, when `activating`, Kinora becomes the wallpaper, which restarts
    /// WallpaperAgent once. Housekeeping (a removed item, an edited playlist) passes false, so it
    /// never takes the desktop back from the wallpaper the user chose instead.
    func apply(_ rules: WallpaperRules, activating: Bool = true) async {
        working = true
        defer { working = false }
        do {
            try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
            if let old = selection?.rules.schedule, !old.isEmpty, rules.schedule?.isEmpty ?? true, old != previousSchedule {
                rememberSchedule(old)
            }
            try KinoraSelection(rules: rules).encoded().write(to: location.selection, options: .atomic)
            LibraryModel.postLibraryChanged()
            if !followsSelection, activating {
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

    /// A schedule the editor can offer to bring back: the one Kinora last replaced, or the one
    /// Kinora showed before another wallpaper took over. Nil while a schedule is in force.
    var restorableSchedule: [WallpaperRules.ScheduleEntry]? {
        guard liveRules?.schedule?.isEmpty ?? true else { return nil }
        let candidate = previousSchedule ?? (followsSelection ? nil : selection?.rules.schedule)
        return candidate?.isEmpty == false ? candidate : nil
    }

    private static let previousScheduleKey = "previousSchedule"

    nonisolated private static func loadPreviousSchedule() -> [WallpaperRules.ScheduleEntry]? {
        UserDefaults.standard.data(forKey: previousScheduleKey).flatMap { try? JSONDecoder().decode([WallpaperRules.ScheduleEntry].self, from: $0) }
    }

    private func rememberSchedule(_ entries: [WallpaperRules.ScheduleEntry]) {
        previousSchedule = entries
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.previousScheduleKey) }
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
