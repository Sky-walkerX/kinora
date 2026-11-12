// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import IOSurface

// The message objects WallpaperAgent and a wallpaper plug-in exchange over NSXPC. The class
// names must match WallpaperExtensionKit's exactly, since NSXPC sends them by name. Each holds
// one Swift value as JSON under a key named after its type (read from macOS 27.0.1, see
// docs/spikes). Every class must say it supports secure coding itself, or NSXPC drops the message.

/// Base for the classes that carry one JSON value under a fixed key.
class JSONMessage: NSObject, NSSecureCoding, @unchecked Sendable {
    class var supportsSecureCoding: Bool { true }
    class var key: String { preconditionFailure("subclasses name their key") }

    let json: Data

    init(json: Data) {
        self.json = json
        super.init()
    }

    convenience init(object: Any) {
        self.init(json: (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data())
    }

    required init?(coder: NSCoder) {
        guard let data = coder.decodeObject(of: NSData.self, forKey: Self.key) else { return nil }
        json = data as Data
        super.init()
    }

    func encode(with coder: NSCoder) { coder.encode(json as NSData, forKey: Self.key) }
}

@objc(WallpaperIDXPC) final class WallpaperIDXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "WallpaperID" }
}

@objc(WallpaperUpdateRequestXPC) final class WallpaperUpdateRequestXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "WallpaperUpdateRequest" }
}

/// The reply to acquire: the remote CAContext's ID as a JSON number.
@objc(WallpaperRemoteContextXPC) final class WallpaperRemoteContextXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "UInt32" }
}

@objc(WallpaperSettingsViewModelsXPC) final class WallpaperSettingsViewModelsXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "WallpaperSettingsViewModels" }
}

@objc(WallpaperContentTypeSetXPC) final class WallpaperContentTypeSetXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "Set<ContentType>" }
}

@objc(WallpaperChoiceIDXPC) final class WallpaperChoiceIDXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "ID" }
}

@objc(WallpaperChoiceIDsXPC) final class WallpaperChoiceIDsXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "Array<ID>" }
}

@objc(WallpaperMigrationVersionXPC) final class WallpaperMigrationVersionXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "WallpaperMigrationVersion" }
}

@objc(WallpaperDebugRequestXPC) final class WallpaperDebugRequestXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "WallpaperDebugRequest" }
}

@objc(WallpaperDebugResponseXPC) final class WallpaperDebugResponseXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "WallpaperDebugResponse" }
}

@objc(WallpaperExtensionChoiceRequestXPC) final class WallpaperExtensionChoiceRequestXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "WallpaperChoiceRequest" }
}

@objc(WallpaperChoiceRequestAdditionResultXPC) final class WallpaperChoiceRequestAdditionResultXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "WallpaperChoiceRequestAdditionResult" }
}

@objc(AuditTokenXPC) final class AuditTokenXPC: JSONMessage, @unchecked Sendable {
    override class var supportsSecureCoding: Bool { true }
    override class var key: String { "audit_token_t" }
}

/// Asks for a new surface. Files arrive as security-scoped wrappers beside the JSON.
@objc(WallpaperCreationRequestXPC) final class WallpaperCreationRequestXPC: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }

    let json: Data

    required init?(coder: NSCoder) {
        if let wrapper = NSClassFromString("NSSecurityScopedURLWrapper") {
            // Decoded so the coder accepts the message; Kinora's choices carry no files.
            _ = coder.decodeArrayOfObjects(ofClasses: [wrapper], forKey: "files")
            _ = coder.decodeObject(of: [wrapper], forKey: "cacheDirectory")
        }
        guard let data = coder.decodeObject(of: NSData.self, forKey: "codable") else { return nil }
        json = data as Data
        super.init()
    }

    func encode(with coder: NSCoder) { coder.encode(json as NSData, forKey: "codable") }
}

/// A still of a surface, as an IOSurface. It only travels over an NSXPCCoder, under "surface".
@objc(WallpaperSnapshotXPC) final class WallpaperSnapshotXPC: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }

    let surface: IOSurfaceRef?

    init(surface: IOSurfaceRef) {
        self.surface = surface
        super.init()
    }

    required init?(coder: NSCoder) {
        guard let xpc = coder as? NSXPCCoder, let object = xpc.decodeXPCObject(ofType: XPC_TYPE_DICTIONARY, forKey: "surface") else { return nil }
        surface = IOSurfaceLookupFromXPCObject(object)
        super.init()
    }

    func encode(with coder: NSCoder) {
        guard let xpc = coder as? NSXPCCoder, let surface else { return }
        xpc.encodeXPCObject(IOSurfaceCreateXPCObject(surface), forKey: "surface")
    }
}
