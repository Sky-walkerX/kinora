// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import KinoraKit
import Security

/// Receives WallpaperAgent's calls on NSXPC's queues, decodes them, and hands them to the
/// service on the main actor. Every call replies, including the ones Kinora does not support,
/// so WallpaperAgent never waits on a dropped message.
final class XPCEndpoint: NSObject, KinoraWallpaperXPC, @unchecked Sendable {
    static let shared = XPCEndpoint()

    @MainActor private lazy var service: WallpaperService = {
        let service = WallpaperService()
        service.publishSettingsViewModels = { [weak self] json in self?.publish(json) }
        return service
    }()

    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []

    func accept(_ connection: NSXPCConnection) -> Bool {
        // Only Apple's own code hosts wallpaper plug-ins. ExtensionKit enforces that too (the plug-in
        // point admits only hosts with Apple's private extension-host entitlement); this check fails
        // closed on top of it. NSXPCConnection's setCodeSigningRequirement and auditToken both need
        // a libxpc connection these BoardServices-brokered connections don't have, so the peer is
        // looked up by process ID, which cannot be reused while its connection is open.
        let signature = Self.peerSignature(of: connection)
        guard signature == .apple else {
            log.error("refused a connection from pid \(connection.processIdentifier): signature \(String(describing: signature), privacy: .public)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: KinoraWallpaperXPC.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: KinoraWallpaperHostXPC.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.lock.withLock { self.connections.removeAll { $0 === connection } }
        }
        lock.withLock { connections.append(connection) }
        connection.resume()
        log.notice("host connected, pid \(connection.processIdentifier), signed by Apple")
        return true
    }

    enum PeerSignature { case apple, notApple, unknown }

    /// Checks the connecting process's signature against "anchor apple". `unknown` when the peer
    /// cannot be inspected, which is refused like `notApple`.
    static func peerSignature(of connection: NSXPCConnection) -> PeerSignature {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: connection.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return .unknown }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess, let requirement else { return .unknown }
        let status = SecCodeCheckValidity(code, [], requirement)
        if status == errSecSuccess { return .apple }
        return status == errSecCSReqFailed ? .notApple : .unknown
    }

    private func publish(_ json: Data) {
        let current = lock.withLock { connections }
        for connection in current {
            let host = connection.remoteObjectProxyWithErrorHandler { error in
                log.error("updating System Settings tiles failed: \(error.localizedDescription, privacy: .public)")
            } as? KinoraWallpaperHostXPC
            host?.updateSettingsViewModels(WallpaperSettingsViewModelsXPC(json: json)) { _ in }
        }
    }

    private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }

    // MARK: - Surfaces

    func acquire(_ id: WallpaperIDXPC, request: WallpaperCreationRequestXPC, reply: @escaping @Sendable (WallpaperRemoteContextXPC?, Error?) -> Void) {
        guard let key = WallpaperRequestDecoding.wallpaperID(from: id.json),
              let decoded = WallpaperRequestDecoding.creationRequest(from: request.json)
        else { return reply(nil, PlugInError.cannotRender) }
        Self.onMain {
            if let contextID = self.service.acquire(id: key, request: decoded) {
                reply(WallpaperRemoteContextXPC(object: contextID), nil)
            } else {
                reply(nil, PlugInError.cannotRender)
            }
        }
    }

    func update(_ id: WallpaperIDXPC, request: WallpaperUpdateRequestXPC, reply: @escaping @Sendable (Error?) -> Void) {
        guard let key = WallpaperRequestDecoding.wallpaperID(from: id.json),
              let decoded = WallpaperRequestDecoding.updateRequest(from: request.json)
        else { return reply(PlugInError.noSuchSurface) }
        Self.onMain { reply(self.service.update(id: key, request: decoded) ? nil : PlugInError.noSuchSurface) }
    }

    func invalidate(_ id: WallpaperIDXPC, reply: @escaping @Sendable (Error?) -> Void) {
        guard let key = WallpaperRequestDecoding.wallpaperID(from: id.json) else { return reply(nil) }
        Self.onMain { self.service.invalidate(id: key); reply(nil) }
    }

    func snapshot(_ id: WallpaperIDXPC, reply: @escaping @Sendable (WallpaperSnapshotXPC?, Error?) -> Void) {
        guard let key = WallpaperRequestDecoding.wallpaperID(from: id.json) else { return reply(nil, PlugInError.noSuchSurface) }
        Self.onMain {
            Task { @MainActor in
                if let surface = await self.service.snapshot(id: key) {
                    reply(WallpaperSnapshotXPC(surface: surface), nil)
                } else {
                    reply(nil, PlugInError.noSnapshot)
                }
            }
        }
    }

    func provideSettingsViewModels(_ types: WallpaperContentTypeSetXPC, reply: @escaping @Sendable (WallpaperSettingsViewModelsXPC?, Error?) -> Void) {
        Self.onMain { reply(WallpaperSettingsViewModelsXPC(json: self.service.settingsViewModels()), nil) }
    }

    // MARK: - Choices

    func selectedChoicesDidChange(_ ids: WallpaperChoiceIDsXPC, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func isChoiceDownloaded(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (NSNumber?, Error?) -> Void) { reply(NSNumber(value: true), nil) }
    func handleNotification(_ name: NSString, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func migrateSelectedChoice(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (WallpaperChoiceIDXPC?, Error?) -> Void) { reply(id, nil) }
    func migrate(_ from: WallpaperMigrationVersionXPC, to: WallpaperMigrationVersionXPC, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }

    // MARK: - Unsupported: Kinora has no downloads, shuffles, choice requests or debug hooks yet

    func addChoiceRequest(_ request: WallpaperExtensionChoiceRequestXPC, onBehalfOf process: AuditTokenXPC, reply: @escaping @Sendable (WallpaperChoiceRequestAdditionResultXPC?, Error?) -> Void) { reply(nil, PlugInError.unsupported) }
    func removeChoiceRequest(_ request: WallpaperExtensionChoiceRequestXPC, reply: @escaping @Sendable (Error?) -> Void) { reply(PlugInError.unsupported) }
    func canSkipShuffledContent(_ id: WallpaperIDXPC, reply: @escaping @Sendable (Bool, Error?) -> Void) { reply(false, nil) }
    func skipShuffledContent(_ id: WallpaperIDXPC, reply: @escaping @Sendable (Error?) -> Void) { reply(PlugInError.unsupported) }
    func download(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (Error?) -> Void) -> Progress {
        reply(nil)
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        return progress
    }
    func cancelDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func pauseDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func resumeDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func removeDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func handleDebugRequest(_ request: WallpaperDebugRequestXPC, reply: @escaping @Sendable (WallpaperDebugResponseXPC?, Error?) -> Void) { reply(nil, PlugInError.unsupported) }
    func invokeContextMenuAction(_ item: NSString, groupItemID group: NSString, reply: @escaping @Sendable (Error?) -> Void) { reply(PlugInError.unsupported) }
}
