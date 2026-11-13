// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import ImageIO
import KinoraKit
import KinoraRender
import SwiftUI
import UniformTypeIdentifiers

/// Kinora's built-in generative wallpapers.
struct OriginalsPage: View {
    @Environment(LibraryModel.self) private var library
    @Environment(WallpaperController.self) private var wallpaper
    @Binding var selection: UUID?

    var body: some View {
        Group {
            if OriginalRenderer.shared == nil {
                ContentUnavailableView("Kinora Originals Need Metal", systemImage: "cpu",
                                       description: Text("This Mac's graphics don't support Metal, which Kinora's generative wallpapers are drawn with."))
            } else {
                LibraryGrid(items: KinoraOriginals.all.map(\.libraryItem), selection: $selection)
            }
        }
        .navigationSubtitle("Kinora Originals")
    }
}

/// An original moving, as it will on the desktop. Drawn small, at the original's frame rate.
struct OriginalPreview: View {
    let original: KinoraOriginal
    @State private var location = ApproximateLocation.current()
    @State private var started = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / Double(original.framesPerSecond), paused: reduceMotion)) { timeline in
            let seconds = timeline.date.timeIntervalSince(started) + 120
            let sky = original.usesSun ? SkySample.at(Date(), location: location) : .afternoon
            if let renderer = OriginalRenderer.shared,
               let image = try? renderer.image(original, width: 640, height: 400, time: seconds, sky: sky) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(16 / 10, contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary).aspectRatio(16 / 10, contentMode: .fit)
            }
        }
        .accessibilityLabel("Preview of \(original.name)")
    }
}

/// The inspector's section for an original.
struct OriginalInspectorSection: View {
    @Environment(WallpaperController.self) private var wallpaper
    let original: KinoraOriginal

    var body: some View {
        Section {
            OriginalPreview(original: original)
                .clipShape(.rect(cornerRadius: 10))
                .listRowInsets(EdgeInsets())
            Text(original.name).font(.headline)
            Text(original.summary).foregroundStyle(.secondary)
            LabeledContent("Drawn at", value: "\(original.framesPerSecond) frames a second, \(Int(original.renderScale * 100))% resolution")
            if original.usesSun {
                Text("Follows the sun where your Mac is, worked out from its time zone. Kinora never asks for your location.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if wallpaper.currentItem == original.id {
                Label("On your desktop", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await wallpaper.use(itemID: original.id) }
                } label: {
                    Label("Use as Wallpaper", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(wallpaper.working)
            }
        }
    }
}

/// Draws each original's thumbnail once, for the library and System Settings' tiles. The
/// plug-in cannot write the library, so the app makes them.
enum OriginalThumbnails {
    /// Returns true when it drew any.
    static func ensure(in folder: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let renderer = OriginalRenderer.shared else { return false }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var drew = false
            for original in KinoraOriginals.all {
                let url = folder.appendingPathComponent(original.thumbnailName)
                guard !FileManager.default.fileExists(atPath: url.path),
                      let image = try? renderer.image(original, width: 1280, height: 800, time: 240, sky: .afternoon),
                      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                drew = CGImageDestinationFinalize(destination) || drew
            }
            return drew
        }.value
    }
}
