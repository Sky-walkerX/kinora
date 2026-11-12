// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import Foundation

// What WallpaperAgent sends a wallpaper plug-in, as JSON inside its XPC message objects.
// The shapes were read from macOS 27.0.1 (see docs/spikes). Every field is optional and
// unknown enum cases are kept rather than rejected, so a macOS update that adds or drops a
// field degrades gracefully instead of failing to decode the whole request.

/// Where macOS shows a surface. `locked` is the Lock Screen; `idle` is the screen saver.
public enum PresentationMode: Equatable, Sendable {
    case `default`, locked, idle
    case unknown(String)
}

/// Whether macOS wants the surface animating.
public enum ActivityState: Equatable, Sendable {
    case active, suspended
    case unknown(String)
}

public enum SystemAppearance: Equatable, Sendable {
    case light, dark
    case unknown(String)
}

/// The display a surface is for.
public struct WallpaperDestination: Equatable, Sendable {
    /// In points.
    public var size: CGSize?
    public var scaleFactor: Double?
    public var directDisplayID: UInt32?

    public init(size: CGSize? = nil, scaleFactor: Double? = nil, directDisplayID: UInt32? = nil) {
        self.size = size
        self.scaleFactor = scaleFactor
        self.directDisplayID = directDisplayID
    }

    /// The largest surface side Kinora draws, in pixels. Far beyond any display, and small
    /// enough that a corrupt request cannot make Kinora allocate gigabytes or trap.
    public static let maxPixelSide = 16_384

    /// The surface's size in pixels, or nil when the request did not say or made no sense.
    public var pixelSize: (width: Int, height: Int)? {
        guard let size, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let scale = min(8, max(1, (scaleFactor ?? 1).isFinite ? (scaleFactor ?? 1) : 1))
        let limit = Double(Self.maxPixelSide)
        let width = min(limit, max(1, (size.width * scale).rounded()))
        let height = min(limit, max(1, (size.height * scale).rounded()))
        return (Int(width), Int(height))
    }
}

/// Sent with `acquireWithId:request:reply:` when macOS wants a new surface.
public struct WallpaperCreationRequest: Equatable, Sendable {
    /// The choice's configuration as stored in the wallpaper store. Absent for previews.
    public var configuration: Data?
    public var isPreview: Bool
    public var presentationMode: PresentationMode
    public var activityState: ActivityState
    public var systemAppearance: SystemAppearance
    public var destination: WallpaperDestination
}

/// Sent with `updateWithId:request:reply:`, for example when the Mac locks or unlocks.
public struct WallpaperUpdateRequest: Equatable, Sendable {
    public var presentationMode: PresentationMode
    public var activityState: ActivityState
    public var systemAppearance: SystemAppearance
    public var destination: WallpaperDestination
}

public enum WallpaperRequestDecoding {
    public static func creationRequest(from json: Data) -> WallpaperCreationRequest? {
        guard let object = jsonObject(json) else { return nil }
        return WallpaperCreationRequest(
            configuration: (object["configuration"] as? String).flatMap { Data(base64Encoded: $0) },
            isPreview: object["isPreview"] as? Bool ?? false,
            presentationMode: presentationMode(object["presentationMode"]),
            activityState: activityState(object["activityState"]),
            systemAppearance: systemAppearance(object["systemAppearance"]),
            destination: destination(object["destination"])
        )
    }

    public static func updateRequest(from json: Data) -> WallpaperUpdateRequest? {
        guard let object = jsonObject(json) else { return nil }
        return WallpaperUpdateRequest(
            presentationMode: presentationMode(object["presentationMode"]),
            activityState: activityState(object["activityState"]),
            systemAppearance: systemAppearance(object["systemAppearance"]),
            destination: destination(object["destination"])
        )
    }

    /// The `id` inside a WallpaperID message, which names one surface for its whole life.
    public static func wallpaperID(from json: Data) -> String? {
        (jsonObject(json)?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Pieces

    /// Swift's synthesized Codable writes an enum case without payload as `{"name": {}}`.
    /// A bare string is accepted too, in case a later macOS switches to raw values.
    static func caseName(_ value: Any?) -> String? {
        if let name = value as? String { return name }
        if let dict = value as? [String: Any], dict.count == 1 { return dict.keys.first }
        return nil
    }

    static func presentationMode(_ value: Any?) -> PresentationMode {
        switch caseName(value) {
        case "default", nil: .default
        case "locked": .locked
        case "idle": .idle
        case let other?: .unknown(other)
        }
    }

    static func activityState(_ value: Any?) -> ActivityState {
        switch caseName(value) {
        case "active", nil: .active
        case "suspended": .suspended
        case let other?: .unknown(other)
        }
    }

    static func systemAppearance(_ value: Any?) -> SystemAppearance {
        switch caseName(value) {
        case "light": .light
        case "dark", nil: .dark
        case let other?: .unknown(other)
        }
    }

    static func destination(_ value: Any?) -> WallpaperDestination {
        guard let dict = value as? [String: Any] else { return WallpaperDestination() }
        var size: CGSize?
        if let pair = dict["size"] as? [Double], pair.count == 2 { size = CGSize(width: pair[0], height: pair[1]) }
        let display = (dict["directDisplayID"] as? NSNumber).map { UInt32(truncatingIfNeeded: $0.int64Value) }
        return WallpaperDestination(size: size, scaleFactor: (dict["scaleFactor"] as? NSNumber)?.doubleValue, directDisplayID: display)
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
