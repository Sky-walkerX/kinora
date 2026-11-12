// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// Pure edits to WallpaperAgent's store, `~/Library/Application Support/com.apple.wallpaper/
/// Store/Index.plist`. The store nests a node per scope (all spaces and displays, single
/// displays, spaces), each holding `Desktop`, `Idle` (the screen saver) and sometimes `Linked`
/// entries whose `Content.Choices` names a provider. The nesting differs between Macs, so edits
/// find entries by shape instead of by fixed path.
public enum WallpaperStoreEditor {
    /// Entries Kinora replaces when the user picks a Kinora wallpaper for every display. `Idle`,
    /// the screen saver, is left alone.
    static let editedEntries: Set<String> = ["Desktop", "Linked"]

    /// The node macOS falls back to when nothing else applies. Kinora never edits it.
    static let untouchedScopes: Set<String> = ["SystemDefault"]

    /// The store with every desktop entry set to show Kinora with `configuration`.
    public static func selectingKinora(_ store: [String: Any], configuration: Data, now: Date) -> [String: Any] {
        var result = store
        for (key, value) in store where !untouchedScopes.contains(key) {
            if let node = value as? [String: Any] { result[key] = rewrite(node, configuration: configuration, now: now) }
        }
        return result
    }

    /// The provider of the first choice in every desktop entry, outermost scope first.
    public static func desktopProviders(_ store: [String: Any]) -> [String] {
        var providers: [String] = []
        collect(store, skipping: untouchedScopes) { entry in
            if let provider = firstChoice(entry)?["Provider"] as? String { providers.append(provider) }
        }
        return providers
    }

    /// True when the store shows Kinora on the desktop for every scope that sets a desktop.
    public static func kinoraIsSelected(_ store: [String: Any]) -> Bool {
        let providers = desktopProviders(store)
        return !providers.isEmpty && providers.allSatisfy { $0 == KinoraIdentity.providerID }
    }

    /// The configuration of the first Kinora desktop choice, if any.
    public static func kinoraConfiguration(_ store: [String: Any]) -> Data? {
        var found: Data?
        collect(store, skipping: untouchedScopes) { entry in
            guard found == nil, let choice = firstChoice(entry), choice["Provider"] as? String == KinoraIdentity.providerID else { return }
            found = choice["Configuration"] as? Data
        }
        return found
    }

    // MARK: - Internals

    static func content(configuration: Data) -> [String: Any] {
        let noOptions = (try? PropertyListSerialization.data(fromPropertyList: ["values": [String: Any]()], format: .binary, options: 0)) ?? Data()
        return [
            "Choices": [["Provider": KinoraIdentity.providerID, "Configuration": configuration, "Files": [Any]()]],
            "EncodedOptionValues": noOptions,
            "Shuffle": "$null",
        ]
    }

    static func rewrite(_ node: [String: Any], configuration: Data, now: Date) -> [String: Any] {
        var result = node
        for (key, value) in node {
            guard var child = value as? [String: Any] else { continue }
            if editedEntries.contains(key), child["Content"] is [String: Any] {
                child["Content"] = content(configuration: configuration)
                child["LastSet"] = now
                result[key] = child
            } else if key != "Idle" {
                result[key] = rewrite(child, configuration: configuration, now: now)
            }
        }
        return result
    }

    static func collect(_ node: [String: Any], skipping: Set<String> = [], _ visit: ([String: Any]) -> Void) {
        for key in node.keys.sorted() where !skipping.contains(key) {
            guard let child = node[key] as? [String: Any] else { continue }
            if editedEntries.contains(key), child["Content"] is [String: Any] {
                visit(child)
            } else if key != "Idle" {
                collect(child, visit)
            }
        }
    }

    static func firstChoice(_ entry: [String: Any]) -> [String: Any]? {
        ((entry["Content"] as? [String: Any])?["Choices"] as? [[String: Any]])?.first
    }
}
