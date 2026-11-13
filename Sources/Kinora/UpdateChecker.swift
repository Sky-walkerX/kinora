// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import KinoraKit
import Observation

/// Looks for a newer release on GitHub, only when asked, or weekly if the user turned that on.
/// It reads the latest release's version and page and never downloads or installs anything:
/// the user does that themselves, so nothing unsigned arrives behind their back.
@MainActor @Observable final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case noReleases
        case available(version: String, page: URL)
        case failed
    }

    private(set) var state: State = .idle

    nonisolated static let latestRelease = URL(string: "https://api.github.com/repos/Sky-walkerX/kinora/releases/latest")!
    nonisolated static let releasesPage = ReleaseCheck.releasesPage
    static let automaticKey = "checkForUpdatesAutomatically"
    static let lastCheckKey = "lastUpdateCheck"

    var currentVersion: String { PackageInstaller.kinoraVersion }

    func check() async {
        state = .checking
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: Self.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await GalleryModel.session.data(for: request, delegate: RedirectGuard())
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { state = .noReleases; return }
            guard status == 200, data.count < 1_000_000 else { state = .failed; return }
            state = Self.evaluate(data, current: currentVersion)
        } catch {
            state = .failed
        }
    }

    /// Checks at launch when automatic checks are on and the last one was a week ago or more.
    func checkIfDue() async {
        guard UserDefaults.standard.bool(forKey: Self.automaticKey) else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 86_400 else { return }
        await check()
    }

    /// The state for a GitHub "latest release" response.
    nonisolated static func evaluate(_ data: Data, current: String) -> State {
        switch ReleaseCheck.evaluate(data, current: current) {
        case .upToDate: .upToDate
        case let .available(version, page): .available(version: version, page: page)
        case .unreadable: .failed
        }
    }
}
