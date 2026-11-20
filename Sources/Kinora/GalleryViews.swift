// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CryptoKit
import Foundation
import ImageIO
import KinoraKit
import KinoraMedia
import Observation
import SwiftUI

/// The gallery: a catalog fetched only when the user asks, and downloads only of what they pick.
/// Every request goes to GitHub over HTTPS, without cookies or a cache, and redirects anywhere
/// else are refused.
@MainActor @Observable final class GalleryModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded([GalleryEntry], skipped: Int)
        case unpublished
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Download progress by entry, 0...1.
    private(set) var downloads: [String: Double] = [:]
    /// Entries downloaded and now being checked and installed; that part can't be cancelled.
    private(set) var installing: Set<String> = []
    /// Preview pictures already fetched, by URL, so scrolling doesn't fetch them again.
    private var previews: [URL: CGImage] = [:]
    var lastError: String?
    private var tasks: [String: Task<Void, Never>] = [:]
    let catalogURL: URL

    init(catalogURL: URL = GalleryCatalog.defaultURL) {
        self.catalogURL = catalogURL
    }

    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "Kinora"]
        return URLSession(configuration: configuration)
    }()

    func load() {
        state = .loading
        let url = catalogURL
        Task {
            do {
                let (data, response) = try await Self.fetch(url, limit: Int64(GalleryValidation.catalogBytes))
                if response.statusCode == 404 { state = .unpublished; return }
                guard response.statusCode == 200 else { state = .failed("The gallery answered with an error (\(response.statusCode)). Try again later."); return }
                let (catalog, skipped) = try GalleryValidation.decode(data)
                state = .loaded(catalog.entries, skipped: skipped)
            } catch GalleryValidation.Problem.newerSchema {
                state = .failed("The gallery needs a newer version of Kinora.")
            } catch {
                state = .failed("Kinora couldn't reach the gallery. Check your connection and try again.")
            }
        }
    }

    func download(_ entry: GalleryEntry, into library: LibraryModel) {
        guard tasks[entry.id] == nil else { return }
        downloads[entry.id] = 0
        tasks[entry.id] = Task {
            defer {
                tasks[entry.id] = nil
                downloads[entry.id] = nil
                installing.remove(entry.id)
            }
            do {
                let folder = try library.makeWorkFolder()
                defer { LibraryModel.removeWork(folder) }
                let file = folder.appendingPathComponent("package.kinorawallpaper")
                try await Self.download(entry, to: file) { [weak self] value in
                    Task { @MainActor in if self?.downloads[entry.id] != nil { self?.downloads[entry.id] = value } }
                }
                try Task.checkCancellation()
                installing.insert(entry.id)
                _ = try await PackageInstaller.install(file, into: library, expected: entry)
            } catch is CancellationError {
                // Cancelled by the user; the partial file went with the work folder.
            } catch let error as URLError where error.code == .cancelled {
                // URLSession reports a cancelled download this way.
            } catch let failure as PackageInstaller.Failure {
                lastError = failure.errorDescription
            } catch DownloadFailure.checksum {
                lastError = "“\(entry.name)” didn't download correctly, so Kinora didn't install it. Try again."
            } catch DownloadFailure.tooLarge {
                lastError = "“\(entry.name)” is larger than the gallery said, so Kinora stopped the download."
            } catch let failure as PackageSource.Failure {
                lastError = "Kinora couldn't install “\(entry.name)”. \(failure.errorDescription ?? "")"
            } catch let problem as PackageProblem {
                lastError = "Kinora couldn't install “\(entry.name)”. \(problem.description)"
            } catch {
                lastError = "Kinora couldn't download “\(entry.name)”. Check your connection and try again."
            }
        }
    }

    func cancel(_ entry: GalleryEntry) {
        guard !installing.contains(entry.id) else { return }
        tasks[entry.id]?.cancel()
    }

    /// An entry's preview picture, fetched by the same rules as everything else in the gallery:
    /// GitHub only, no cookies or cache, at most 10 MB, decoded no larger than shown.
    func preview(_ url: URL) async -> CGImage? {
        if let cached = previews[url] { return cached }
        guard let fetched = try? await Self.fetch(url, limit: PackageLimits.previewBytes), fetched.1.statusCode == 200,
              let source = CGImageSourceCreateWithData(fetched.0 as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, LibraryModel.packageImageTypes.contains(type),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 720,
              ] as CFDictionary) else { return nil }
        previews[url] = image
        return image
    }

    // MARK: - Network

    /// The body of `url`, at most `limit` bytes.
    nonisolated static func fetch(_ url: URL, limit: Int64) async throws -> (Data, HTTPURLResponse) {
        guard GalleryValidation.isAllowed(url) else { throw DownloadFailure.notAllowed }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url), delegate: RedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw DownloadFailure.badResponse }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw DownloadFailure.tooLarge }
        }
        return (data, http)
    }

    /// Streams a package to `file`, checking its size against the listing as it goes and its
    /// SHA-256 at the end. A mismatch deletes the file.
    nonisolated static func download(_ entry: GalleryEntry, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard GalleryValidation.isAllowed(entry.download) else { throw DownloadFailure.notAllowed }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: entry.download), delegate: RedirectGuard())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw DownloadFailure.badResponse }
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) else {
            throw DownloadFailure.badResponse
        }
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        do {
            defer { try? handle.close() }
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 16 {
                    received += Int64(buffer.count)
                    guard received <= entry.bytes else { throw DownloadFailure.tooLarge }
                    hasher.update(data: buffer)
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    progress(min(1, Double(received) / Double(entry.bytes)))
                }
            }
            received += Int64(buffer.count)
            guard received <= entry.bytes else { throw DownloadFailure.tooLarge }
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else {
            try? FileManager.default.removeItem(at: file)
            throw DownloadFailure.checksum
        }
        progress(1)
    }
}

enum DownloadFailure: Error { case checksum, tooLarge, badResponse, notAllowed }

/// Refuses redirects to hosts outside the gallery's, plus any `extraHosts`.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let extraHosts: Set<String>

    init(allowing extraHosts: Set<String> = []) {
        self.extraHosts = extraHosts
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url else { return nil }
        if GalleryValidation.isAllowed(url) { return request }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, (url.port ?? 443) == 443,
              let host = url.host?.lowercased(), extraHosts.contains(host) else { return nil }
        return request
    }
}

/// Browsing the gallery. Nothing goes online until the user presses Browse.
struct GalleryPage: View {
    @Environment(LibraryModel.self) private var library
    @Environment(GalleryModel.self) private var gallery

    var body: some View {
        Group {
            switch gallery.state {
            case .idle:
                ContentUnavailableView {
                    Label("Wallpapers Free to Share", systemImage: "square.grid.2x2")
                } description: {
                    Text("The gallery lists wallpapers whose makers allow them to be shared, from NASA, ESA, Wikimedia Commons and others, each with its credit and license. Browsing connects to GitHub, where the gallery is kept, to list the wallpapers and show their previews. Nothing is added to your library until you choose it.")
                } actions: {
                    Button("Browse the Gallery") { gallery.load() }
                        .buttonStyle(.glassProminent)
                }
            case .loading:
                ProgressView("Loading the gallery…")
            case .unpublished:
                ContentUnavailableView("The Gallery Isn't Open Yet", systemImage: "clock",
                                       description: Text("Kinora's gallery hasn't been published. Kinora Originals and Living Photos work without it."))
            case .failed(let message):
                ContentUnavailableView {
                    Label("Gallery Unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { gallery.load() }
                }
            case .loaded(let entries, let skipped):
                if entries.isEmpty {
                    ContentUnavailableView("Nothing Here Yet", systemImage: "square.grid.2x2",
                                           description: Text("The gallery has no wallpapers yet."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18)], spacing: 22) {
                            ForEach(entries) { entry in GalleryCard(entry: entry) }
                        }
                        .padding(22)
                        if skipped > 0 {
                            Text(skipped == 1 ? "1 listing was left out because it didn't meet the gallery's rules." : "\(skipped) listings were left out because they didn't meet the gallery's rules.")
                                .font(.caption).foregroundStyle(.secondary).padding(.bottom)
                        }
                    }
                }
            }
        }
        .navigationSubtitle("Gallery")
        .alert("Gallery", isPresented: Binding(get: { gallery.lastError != nil }, set: { if !$0 { gallery.lastError = nil } })) {
            Button("OK") { gallery.lastError = nil }
        } message: { Text(gallery.lastError ?? "") }
        .toolbar {
            if case .loaded = gallery.state {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reload", systemImage: "arrow.clockwise") { gallery.load() }
                }
            }
        }
    }
}

private struct GalleryCard: View {
    @Environment(LibraryModel.self) private var library
    @Environment(GalleryModel.self) private var gallery
    let entry: GalleryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    if let preview = entry.preview {
                        GalleryPreview(url: preview)
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .clipShape(.rect(cornerRadius: 10))
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name).font(.headline).lineLimit(1)
                if entry.isUltrawide { Text("Ultrawide").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: .capsule) }
                Spacer()
                action
            }
            Text(entry.attribution ?? entry.author).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text(entry.license)
                Text("·")
                Text(entry.bytes.formatted(.byteCount(style: .file)))
                if let source = entry.source {
                    Spacer()
                    Link("Source", destination: source)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var action: some View {
        // Only a copy installed from the gallery counts; a file with the same id is someone else's.
        let installed = library.items.first { $0.packageID == entry.id && ($0.packageOrigin ?? "").hasPrefix("gallery:") }
        if gallery.installing.contains(entry.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let progress = gallery.downloads[entry.id] {
            HStack(spacing: 6) {
                ProgressView(value: progress).frame(width: 60)
                Button("Cancel", systemImage: "xmark.circle.fill") { gallery.cancel(entry) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        } else if let installed, installed.packageVersion == entry.version {
            Label("In Library", systemImage: "checkmark").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
        } else {
            Button(installed != nil ? "Update" : "Get") { gallery.download(entry, into: library) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

/// A gallery entry's preview, loaded through the gallery's own rules rather than the system's
/// shared session, which would follow redirects anywhere and keep cookies and a cache.
private struct GalleryPreview: View {
    @Environment(GalleryModel.self) private var gallery
    let url: URL
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            image = await gallery.preview(url)
            failed = image == nil
        }
    }
}
