// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// What WallpaperAgent calls on a wallpaper plug-in: WallpaperExtensionKit's
/// `WallpaperExtensionXPCProtocol` on macOS 27.0.1, selector for selector, with the argument
/// and reply classes from its extended type encodings. NSXPC matches by selector and
/// signature, so the protocol's own name does not matter.
@objc protocol KinoraWallpaperXPC {
    @objc(acquireWithId:request:reply:)
    func acquire(_ id: WallpaperIDXPC, request: WallpaperCreationRequestXPC, reply: @escaping @Sendable (WallpaperRemoteContextXPC?, Error?) -> Void)
    @objc(updateWithId:request:reply:)
    func update(_ id: WallpaperIDXPC, request: WallpaperUpdateRequestXPC, reply: @escaping @Sendable (Error?) -> Void)
    @objc(invalidateWithId:reply:)
    func invalidate(_ id: WallpaperIDXPC, reply: @escaping @Sendable (Error?) -> Void)
    @objc(snapshotWithId:reply:)
    func snapshot(_ id: WallpaperIDXPC, reply: @escaping @Sendable (WallpaperSnapshotXPC?, Error?) -> Void)
    @objc(provideSettingsViewModelsWithContentTypes:reply:)
    func provideSettingsViewModels(_ types: WallpaperContentTypeSetXPC, reply: @escaping @Sendable (WallpaperSettingsViewModelsXPC?, Error?) -> Void)
    @objc(selectedChoicesDidChangeFor:reply:)
    func selectedChoicesDidChange(_ ids: WallpaperChoiceIDsXPC, reply: @escaping @Sendable (Error?) -> Void)
    @objc(isChoiceDownloadedWith:reply:)
    func isChoiceDownloaded(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (NSNumber?, Error?) -> Void)
    @objc(handleNotificationWithNamed:reply:)
    func handleNotification(_ name: NSString, reply: @escaping @Sendable (Error?) -> Void)
    @objc(migrateSelectedChoiceFor:reply:)
    func migrateSelectedChoice(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (WallpaperChoiceIDXPC?, Error?) -> Void)
    @objc(migrateFrom:to:reply:)
    func migrate(_ from: WallpaperMigrationVersionXPC, to: WallpaperMigrationVersionXPC, reply: @escaping @Sendable (Error?) -> Void)
    @objc(addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:)
    func addChoiceRequest(_ request: WallpaperExtensionChoiceRequestXPC, onBehalfOf process: AuditTokenXPC, reply: @escaping @Sendable (WallpaperChoiceRequestAdditionResultXPC?, Error?) -> Void)
    @objc(removeChoiceRequestWithChoiceRequest:reply:)
    func removeChoiceRequest(_ request: WallpaperExtensionChoiceRequestXPC, reply: @escaping @Sendable (Error?) -> Void)
    @objc(canSkipShuffledContentWithId:reply:)
    func canSkipShuffledContent(_ id: WallpaperIDXPC, reply: @escaping @Sendable (Bool, Error?) -> Void)
    @objc(skipShuffledContentWithId:reply:)
    func skipShuffledContent(_ id: WallpaperIDXPC, reply: @escaping @Sendable (Error?) -> Void)
    @objc(downloadWithChoiceID:reply:)
    func download(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (Error?) -> Void) -> Progress
    @objc(cancelDownloadFor:reply:)
    func cancelDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (Error?) -> Void)
    @objc(pauseDownloadFor:reply:)
    func pauseDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (Error?) -> Void)
    @objc(resumeDownloadFor:reply:)
    func resumeDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (Error?) -> Void)
    @objc(removeDownloadFor:reply:)
    func removeDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (Error?) -> Void)
    @objc(handleDebugRequestFor:reply:)
    func handleDebugRequest(_ request: WallpaperDebugRequestXPC, reply: @escaping @Sendable (WallpaperDebugResponseXPC?, Error?) -> Void)
    @objc(invokeContextMenuActionWithMenuItemID:groupItemID:reply:)
    func invokeContextMenuAction(_ item: NSString, groupItemID group: NSString, reply: @escaping @Sendable (Error?) -> Void)
}

/// What a plug-in may call back on WallpaperAgent: WallpaperExtensionKit's
/// `WallpaperExtensionProxyXPCProtocol`.
@objc protocol KinoraWallpaperHostXPC {
    @objc(updateSettingsViewModels:reply:)
    func updateSettingsViewModels(_ models: WallpaperSettingsViewModelsXPC, reply: @escaping @Sendable (Error?) -> Void)
    @objc(invalidateSnapshotsWithReply:)
    func invalidateSnapshots(reply: @escaping @Sendable (Error?) -> Void)
    @objc(pingWithId:)
    func ping(_ id: WallpaperIDXPC)
}

enum PlugInError: Int, Error, CustomNSError {
    case unsupported = 1
    case noSuchSurface
    case cannotRender
    case noSnapshot

    static var errorDomain: String { "io.github.sky-walkerx.kinora.wallpaper" }
}
