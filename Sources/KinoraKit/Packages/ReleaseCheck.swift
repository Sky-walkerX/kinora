// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// Reads GitHub's "latest release" answer for Kinora. The app only ever tells the user a newer
/// version exists and links to its page; it never downloads or installs anything itself.
public enum ReleaseCheck {
    public static let releasesPage = URL(string: "https://github.com/Sky-walkerX/kinora/releases")!

    public enum Outcome: Equatable, Sendable {
        case upToDate
        case available(version: String, page: URL)
        case unreadable
    }

    public static func evaluate(_ data: Data, current: String) -> Outcome {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = object["tag_name"] as? String else { return .unreadable }
        // Drafts and pre-releases are never offered.
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { return .upToDate }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let latest = Version(version), let installed = Version(current) else { return .unreadable }
        guard latest > installed else { return .upToDate }
        // Only ever send the user to Kinora's own release pages.
        var page = releasesPage
        if let text = object["html_url"] as? String, let url = URL(string: text),
           url.scheme == "https", url.host == "github.com", url.path.hasPrefix("/Sky-walkerX/kinora/") {
            page = url
        }
        return .available(version: version, page: page)
    }
}
