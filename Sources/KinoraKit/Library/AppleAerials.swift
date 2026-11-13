// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// Apple's aerials that macOS has already downloaded. Kinora lists them and plays them where
/// macOS keeps them; it never downloads, copies or deletes them.
///
/// macOS 26 keeps them in `~/Library/Application Support/com.apple.wallpaper/aerials/`, with
/// the catalog in `manifest/entries.json` and each video as `videos/<id>.mov`. macOS 14 and 15
/// used `/Library/Application Support/com.apple.idleassetsd/Customer/`, with `entries.json`
/// and `4KSDR240FPS/<id>.mov`; that location is read too, in case a Mac still has it. Neither
/// is a public interface, so everything here tolerates missing and extra fields.
public enum AppleAerials {
    public struct Aerial: Equatable, Identifiable, Sendable {
        /// Apple's asset identifier, which is also the video's file name without `.mov`.
        public var id: String
        public var name: String
        /// The video's file name, `<id>.mov`.
        public var fileName: String { "\(id).mov" }

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// A place macOS keeps aerials: its catalog, and the folder of downloaded videos.
    public struct Location: Equatable, Sendable {
        public var catalog: URL
        public var videos: URL
    }

    /// Where to look, newest layout first. `home` is the real home folder.
    public static func locations(home: URL) -> [Location] {
        let modern = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
        let legacy = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true)
        return [
            Location(catalog: modern.appendingPathComponent("manifest/entries.json"), videos: modern.appendingPathComponent("videos", isDirectory: true)),
            Location(catalog: legacy.appendingPathComponent("entries.json"), videos: legacy.appendingPathComponent("4KSDR240FPS", isDirectory: true)),
        ]
    }

    /// The video for an aerial's file name: the first location that has it, else the newest
    /// location (where a later download would land).
    public static func videoURL(fileName: String, home: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let candidates = locations(home: home).map { $0.videos.appendingPathComponent(fileName) }
        return candidates.first(where: fileExists) ?? candidates[0]
    }

    /// The aerials in a catalog whose video is downloaded, in the catalog's order, each once.
    /// `downloaded` holds the file names present in the videos folder.
    public static func downloaded(catalog: Data, downloaded: Set<String>) -> [Aerial] {
        guard let root = try? JSONSerialization.jsonObject(with: catalog) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]]
        else { return [] }
        var seen: Set<String> = []
        return assets.compactMap { asset -> Aerial? in
            guard let id = asset["id"] as? String, isAssetID(id), downloaded.contains("\(id).mov"), seen.insert(id).inserted else { return nil }
            return Aerial(id: id, name: displayName(asset))
        }
    }

    /// Apple's identifiers are UUIDs; anything that could be a path is refused.
    public static func isAssetID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") } && isPlainFileName(id)
    }

    /// The asset's English name. `accessibilityLabel` holds it on the versions seen so far;
    /// `localizedNameKey` is a name on some versions and a lookup key on others.
    static func displayName(_ asset: [String: Any]) -> String {
        if let label = (asset["accessibilityLabel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        if let key = (asset["localizedNameKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
           key.contains(" ") || !key.contains("_") {
            return key
        }
        return "Apple Aerial"
    }
}
