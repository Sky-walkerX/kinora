// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import IOSurface
import KinoraKit
import KinoraRender
import notify
import os

let log = Logger(subsystem: "io.github.sky-walkerx.kinora", category: "wallpaper")

/// Where the plug-in keeps its unlock count, in its own sandboxed preferences.
private let unlockCounterKey = "unlockCounter"

/// The plug-in's state: one surface per wallpaper ID WallpaperAgent acquired, the library they
/// draw from, and the rules that decide when they play. Runs on the main actor; the XPC
/// endpoint hops here for every call.
@MainActor final class WallpaperService {
    private struct Record {
        let surface: WallpaperSurface
        let configuration: ChoiceConfiguration?
        var presentation: PresentationMode
        var activity: ActivityState
        var appearance: SystemAppearance
        var destination: WallpaperDestination
        let isPreview: Bool
        var unlockedAt: Date?
    }

    private let location = LibraryLocation.current
    private var records: [String: Record] = [:]
    private var library = LibraryIndex()
    private var selection: KinoraSelection?
    private var settings = PlaybackSettings()
    /// Unlocks counted for a rotation that steps on every unlock, once per lock however many
    /// surfaces report it, and kept across restarts in the plug-in's own preferences.
    private var unlocks = UnlockCounter.decode(UserDefaults.standard.data(forKey: unlockCounterKey)) ?? UnlockCounter()
    private var changeTimer: Timer?
    private let conditions = SystemConditions()
    /// Roughly where the Mac is, from its time zone, for the live sky. Never asks for location.
    private let skyLocation = ApproximateLocation.current()
    private var settleTimer: Timer?
    private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID
    /// Called with fresh System Settings tiles when the library changes.
    var publishSettingsViewModels: (Data) -> Void = { _ in }

    init() {
        reloadLibrary()
        conditions.onChange = { [weak self] in self?.reevaluate() }
        conditions.start()
        notify_register_dispatch(KinoraIdentity.libraryChangedNotification, &notifyToken, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadLibrary()
                self.publishSettingsViewModels(self.settingsViewModels())
            }
        }
    }

    // MARK: - Calls from WallpaperAgent

    func acquire(id: String, request: WallpaperCreationRequest) -> UInt32? {
        records[id]?.surface.tearDown()
        // A plug-in started while the Mac is locked learns it from the surfaces it acquires.
        countUnlock(from: nil, to: request.presentationMode)
        guard let surface = WallpaperSurface(destination: request.destination) else {
            log.error("acquire \(id, privacy: .public): no remote context on this macOS")
            return nil
        }
        let configuration = ChoiceConfiguration.decode(request.configuration)
        // A wallpaper just picked plays for a moment before resting, as after an unlock.
        records[id] = Record(surface: surface, configuration: configuration, presentation: request.presentationMode,
                             activity: request.activityState, appearance: request.systemAppearance,
                             destination: request.destination, isPreview: request.isPreview, unlockedAt: Date())
        showContent(for: id)
        reevaluate()
        log.notice("acquire \(id, privacy: .public) preview=\(request.isPreview) mode=\(String(describing: request.presentationMode), privacy: .public) context=\(surface.contextID)")
        return surface.contextID
    }

    func update(id: String, request: WallpaperUpdateRequest) -> Bool {
        guard var record = records[id] else { return false }
        if record.presentation == .locked, request.presentationMode == .default {
            record.unlockedAt = Date()
        }
        countUnlock(from: record.presentation, to: request.presentationMode)
        let contentMayChange = record.presentation != request.presentationMode || record.appearance != request.systemAppearance
        record.presentation = request.presentationMode
        record.activity = request.activityState
        record.appearance = request.systemAppearance
        if record.destination != request.destination {
            record.destination = request.destination
            record.surface.resize(to: request.destination)
        }
        records[id] = record
        if contentMayChange { refreshContent() }
        reevaluate()
        log.notice("update \(id, privacy: .public) mode=\(String(describing: request.presentationMode), privacy: .public) activity=\(String(describing: request.activityState), privacy: .public)")
        return true
    }

    func invalidate(id: String) {
        records.removeValue(forKey: id)?.surface.tearDown()
        reevaluate()
    }

    func snapshot(id: String) async -> IOSurfaceRef? {
        guard let record = records[id], let size = record.destination.pixelSize else { return nil }
        return await record.surface.snapshot(pixelSize: size)
    }

    func settingsViewModels() -> Data {
        let tiles = library.items.map { item in
            SettingsTile(id: item.id.uuidString, name: item.name, thumbnail: location.thumbnailURL(for: item),
                         configuration: ChoiceConfiguration(wallpaper: item.id))
        }
        // Originals appear once the app has drawn their thumbnails, and only where Metal works.
        let originals = OriginalRenderer.shared == nil ? [] : KinoraOriginals.all.compactMap { original -> SettingsTile? in
            let thumbnail = location.thumbnailFolder.appendingPathComponent(original.thumbnailName)
            guard FileManager.default.fileExists(atPath: thumbnail.path) else { return nil }
            // Badged as video: it moves, and "video" is the one badge case seen to decode.
            return SettingsTile(id: original.id.uuidString, name: original.name, thumbnail: thumbnail,
                                configuration: ChoiceConfiguration(wallpaper: original.id))
        }
        return SettingsViewModels.json(groups: [
            SettingsGroup(id: SettingsViewModels.groupID, name: "Kinora", tiles: tiles),
            SettingsGroup(id: SettingsViewModels.originalsGroupID, name: "Kinora Originals", tiles: originals),
        ])
    }

    // MARK: - Content and playback

    private func countUnlock(from old: PresentationMode?, to new: PresentationMode) {
        guard unlocks.surface(from: old, to: new) else { return }
        UserDefaults.standard.set(unlocks.encoded(), forKey: unlockCounterKey)
    }

    private func reloadLibrary() {
        if let data = try? Data(contentsOf: location.index), let index = LibraryIndex.decode(data) { library = index }
        selection = (try? Data(contentsOf: location.selection)).flatMap(KinoraSelection.decode)
        if unlocks.follow(selection?.rules.rotation) {
            UserDefaults.standard.set(unlocks.encoded(), forKey: unlockCounterKey)
        }
        if let data = try? Data(contentsOf: location.settings), let decoded = try? JSONDecoder().decode(PlaybackSettings.self, from: data) {
            settings = decoded
        }
        refreshContent()
        reevaluate()
    }

    /// Points every surface at the item its rules name now, and arms one timer for the next
    /// scheduled or rotating change.
    private func refreshContent() {
        for id in records.keys { showContent(for: id) }
        let now = Date()
        // Previews carry no configuration and follow Kinora's selection, so they count too.
        let next = records.values.compactMap { ($0.configuration?.rules(selection: selection) ?? selection?.rules)?.nextChange(after: now) }.min()
        changeTimer?.invalidate()
        changeTimer = next.map { date in
            Timer.scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow + 0.5), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshContent() }
            }
        }
    }

    /// Points a surface at the library item its rules name now. A preview carries no
    /// configuration, so it shows Kinora's current selection, or the first item.
    private func showContent(for id: String) {
        guard let record = records[id] else { return }
        let metal = OriginalRenderer.shared != nil
        let resolution = SurfaceResolution.resolve(configuration: record.configuration, selection: selection,
                                                   mode: record.presentation, appearance: record.appearance, at: Date(),
                                                   unlockCount: unlocks.count, library: library.items.map(\.id),
                                                   originalsAvailable: metal)
        // An item deleted from the library falls back to another one the rules name, then
        // Kinora's own selection, then any item, so the surface never goes blank.
        guard let resolved = resolution.shown else {
            log.error("surface \(id, privacy: .public) has nothing to show")
            return
        }
        let wanted = resolution.wanted
        if let wanted, wanted != resolved {
            log.notice("surface \(id, privacy: .public) wanted \(wanted.uuidString, privacy: .public), which is gone; showing \(resolved.uuidString, privacy: .public)")
        }
        // A newly shown wallpaper plays for a moment before resting, as after an unlock.
        if record.surface.itemID != resolved, !record.isPreview {
            records[id]?.unlockedAt = Date()
            log.notice("surface \(id, privacy: .public) shows \(resolved.uuidString, privacy: .public) (\(String(describing: record.presentation), privacy: .public))")
        }
        if let original = KinoraOriginals.original(resolved) {
            if !record.surface.showOriginal(original, settings: settings, location: skyLocation) {
                log.error("surface \(id, privacy: .public) cannot draw \(original.slug, privacy: .public) without Metal")
            }
        } else if let item = library.item(resolved) {
            if let preset = item.preset, let tinted = preset.resolved(id: item.id, name: item.name) {
                if !record.surface.showOriginal(tinted, settings: settings, location: skyLocation) {
                    log.error("surface \(id, privacy: .public) cannot draw preset \(preset.base, privacy: .public) without Metal")
                }
            } else if item.isStill {
                record.surface.showStill(itemID: item.id, media: location.mediaURL(for: item))
            } else {
                record.surface.showVideo(itemID: item.id, media: location.mediaURL(for: item), thumbnail: location.thumbnailURL(for: item),
                                         frameCap: conditions.onBattery ? settings.batteryFrameCap : nil)
            }
        }
    }

    private func reevaluate() {
        var anyDesktop = false
        var nextSettle: Date?
        for (_, record) in records {
            var c = PlaybackConditions()
            c.presentation = record.presentation
            c.activity = record.activity
            c.isPreview = record.isPreview
            c.desktopCoverage = conditions.coverage(of: record.destination.directDisplayID)
            c.onBattery = conditions.onBattery
            c.lowPowerMode = conditions.lowPowerMode
            c.thermal = conditions.thermal
            c.secondsSinceUnlock = record.unlockedAt.map { Date().timeIntervalSince($0) }
            c.reduceMotion = conditions.reduceMotion
            record.surface.apply(PlaybackPolicy.decide(c, settings: settings))
            if record.presentation == .default, !record.isPreview { anyDesktop = true }
            if settings.settleAfterUnlock, let unlocked = record.unlockedAt {
                let settle = unlocked.addingTimeInterval(settings.settleDelay)
                if settle > Date() { nextSettle = min(nextSettle ?? settle, settle) }
            }
        }
        // Coverage matters both for pausing when covered and for waking a resting wallpaper.
        conditions.watchCoverage(anyDesktop && (settings.pauseWhenCovered || settings.settleAfterUnlock))
        settleTimer?.invalidate()
        settleTimer = nextSettle.map { date in
            Timer.scheduledTimer(withTimeInterval: date.timeIntervalSinceNow + 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            }
        }
    }
}
