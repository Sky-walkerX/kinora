// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// Wallpapers made for Lively (Windows, `LivelyInfo.json`) or Wallpaper Engine (`project.json`),
/// from folders the user already has. Kinora imports the ones that are media it can play, and
/// says plainly why it can't import the rest. It never runs a wallpaper's programs or scripts,
/// and never needs Steam.
///
/// Lively's fields come from its GPL-3.0 source (`LivelyInfoModel` and `WallpaperType`, where
/// `Type` is a number in declaration order). Wallpaper Engine's `project.json` is read for its
/// `title`, `type`, `file` and `preview`. Only the file formats are used, no code.
public enum ForeignWallpaper {
    public enum Source: String, Sendable {
        case lively = "Lively"
        case wallpaperEngine = "Wallpaper Engine"
    }

    public enum Kind: Equatable, Sendable {
        case video(file: String)
        case gif(file: String)
        case picture(file: String)
        case web
        case scene
        case program
        case stream
        case unknown(String)
    }

    public struct Wallpaper: Equatable, Sendable {
        public var source: Source
        public var title: String
        public var author: String?
        public var license: String?
        public var kind: Kind
    }

    public static let livelyManifest = "LivelyInfo.json"
    public static let wallpaperEngineManifest = "project.json"
    public static let manifestBytes = 256 * 1024

    /// Which kind of manifest a folder holds, by the file names in it.
    public static func manifest(in names: Set<String>) -> (source: Source, file: String)? {
        if names.contains(livelyManifest) { return (.lively, livelyManifest) }
        if names.contains(wallpaperEngineManifest) { return (.wallpaperEngine, wallpaperEngineManifest) }
        return nil
    }

    public static func parse(_ data: Data, source: Source, folderName: String) -> Wallpaper? {
        guard data.count <= manifestBytes,
              let object = (try? JSONSerialization.jsonObject(with: stripBOM(data))) as? [String: Any] else { return nil }
        switch source {
        case .lively: return lively(object, folderName: folderName)
        case .wallpaperEngine: return wallpaperEngine(object, folderName: folderName)
        }
    }

    /// Lively's `WallpaperType`, in declaration order.
    static let livelyTypes = ["app", "web", "webaudio", "url", "bizhawk", "unity", "godot", "video", "gif", "unityaudio", "videostream", "picture"]

    static func lively(_ o: [String: Any], folderName: String) -> Wallpaper {
        let typeName: String
        if let number = o["Type"] as? Int, livelyTypes.indices.contains(number) {
            typeName = livelyTypes[number]
        } else if let name = o["Type"] as? String {
            typeName = name.lowercased()
        } else {
            typeName = "unknown"
        }
        let file = (o["FileName"] as? String).flatMap { relativePath($0) }
        // Lively can point at files anywhere on a Windows PC; those cannot come along.
        let absolute = o["IsAbsolutePath"] as? Bool == true
        let kind: Kind
        switch typeName {
        case "video": kind = file.map { absolute ? .unknown("absolute") : .video(file: $0) } ?? .unknown("video")
        case "gif": kind = file.map { absolute ? .unknown("absolute") : .gif(file: $0) } ?? .unknown("gif")
        case "picture": kind = file.map { absolute ? .unknown("absolute") : .picture(file: $0) } ?? .unknown("picture")
        case "web", "webaudio", "url": kind = .web
        case "app", "bizhawk", "unity", "godot", "unityaudio": kind = .program
        case "videostream": kind = .stream
        default: kind = .unknown(typeName)
        }
        return Wallpaper(source: .lively, title: title(o["Title"], fallback: folderName), author: text(o["Author"]),
                         license: text(o["License"]), kind: kind)
    }

    static func wallpaperEngine(_ o: [String: Any], folderName: String) -> Wallpaper {
        let type = (o["type"] as? String)?.lowercased() ?? "unknown"
        let file = (o["file"] as? String).flatMap { relativePath($0) }
        let kind: Kind
        switch type {
        case "video": kind = file.map { .video(file: $0) } ?? .unknown("video")
        case "web": kind = .web
        case "scene": kind = .scene
        case "application": kind = .program
        default: kind = .unknown(type)
        }
        return Wallpaper(source: .wallpaperEngine, title: title(o["title"], fallback: folderName), author: nil, license: nil, kind: kind)
    }

    /// Whether Kinora can import a kind, and if not, why, in words for the user.
    public static func support(_ wallpaper: Wallpaper) -> Result<String, Unsupported> {
        switch wallpaper.kind {
        case .video(let file), .gif(let file), .picture(let file):
            let ext = (file as NSString).pathExtension.lowercased()
            if ["webm", "mkv"].contains(ext) { return .failure(.webm) }
            return .success(file)
        case .web: return .failure(.web)
        case .scene: return .failure(.scene)
        case .program: return .failure(.program)
        case .stream: return .failure(.stream)
        case .unknown(let detail): return .failure(detail == "absolute" ? .elsewhere : .unknown)
        }
    }

    public enum Unsupported: Error, Equatable, Sendable, CustomStringConvertible {
        case webm, web, scene, program, stream, elsewhere, unknown

        public var description: String {
            switch self {
            case .webm:
                "Its video is WebM or MKV, which macOS can't open directly. Kinora can't convert these yet; convert it to MP4 (H.264 or HEVC) first."
            case .web:
                "It's a web wallpaper. Kinora doesn't show web wallpapers yet: whether they can run safely inside macOS's wallpaper system is still being tested."
            case .scene:
                "It's a Wallpaper Engine scene. Scenes need Wallpaper Engine's own renderer, which Kinora doesn't include. Look for a video version of it, or try a Kinora Original."
            case .program:
                "It's a program made for Windows. Kinora plays wallpapers as media and never runs programs."
            case .stream:
                "It streams video from the internet. Kinora only plays files on your Mac."
            case .elsewhere:
                "Its video was elsewhere on the PC it came from, not in its folder."
            case .unknown:
                "Kinora doesn't recognise this kind of wallpaper."
            }
        }
    }

    // MARK: - Pieces

    /// A relative path inside the wallpaper's folder, with Windows separators turned around.
    /// Nil for anything absolute or climbing out with "..".
    public static func relativePath(_ raw: String) -> String? {
        let path = raw.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"), path.count <= 255 else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 4, parts.allSatisfy({ isPlainFileName(String($0)) }) else { return nil }
        return parts.joined(separator: "/")
    }

    static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return String(string.prefix(PackageLimits.authorLength))
    }

    static func title(_ value: Any?, fallback: String) -> String {
        String((text(value) ?? fallback).prefix(PackageLimits.nameLength))
    }

    static func stripBOM(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    }
}
