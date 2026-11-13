// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import KinoraMedia
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Making one Living Photo: a quick preview first, then the full loop, which the user can cancel.
@MainActor @Observable final class LivingPhotoMaker {
    enum Phase: Equatable {
        case choosing
        case preparing
        case previewing
        case generating(Double)
        case failed(String)
    }

    private(set) var phase: Phase = .choosing
    private(set) var photo: URL?
    private(set) var preview: LivingPhotoRenderer?
    var motion: LivingPhotoMotion = .subtle {
        didSet { preview?.setMotion(motion) }
    }
    private var work: Task<Void, Never>?

    /// The preview's width in pixels: enough to judge motion and edges, quick to prepare.
    static let previewWidth = 960.0

    var subjectSummary: String {
        guard let detection = preview?.detection else { return "" }
        if detection.lifted {
            return detection.count == 1 ? "Kinora found a subject and lifts it off the background."
                : "Kinora found \(detection.count) subjects and lifts them off the background."
        }
        if detection.failure != nil { return "Kinora couldn't look for a subject, so the whole photo drifts gently." }
        if detection.count > 0 { return "The subject is too small or too large to lift cleanly, so the whole photo drifts gently." }
        return "No clear subject, so the whole photo drifts gently."
    }

    func choose(_ url: URL, display: CGSize) {
        cancel()
        photo = url
        phase = .preparing
        preview = nil
        let output = CGSize(width: Self.previewWidth, height: (Self.previewWidth * display.height / max(1, display.width)).rounded())
        let motion = motion
        work = Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let renderer = try await Task.detached(priority: .userInitiated) {
                    try LivingPhotoRenderer(photo: url, output: output, motion: motion)
                }.value
                guard !Task.isCancelled else { return }
                preview = renderer
                phase = .previewing
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(Self.describe(error))
            }
        }
    }

    /// Renders the full loop at the display's size and adds it to the library.
    func generate(into library: LibraryModel, display: CGSize, onDone: @escaping (LibraryItem) -> Void) {
        guard let photo else { return }
        work?.cancel()
        phase = .generating(0)
        let output = VideoOptimization.targetSize(source: display, display: display)
        let motion = motion
        work = Task {
            let scoped = photo.startAccessingSecurityScopedResource()
            defer { if scoped { photo.stopAccessingSecurityScopedResource() } }
            var folder: URL?
            do {
                let workFolder = try library.makeWorkFolder()
                folder = workFolder
                let result = try await LivingPhotoGenerator.generate(photo: photo, output: output, motion: motion, workFolder: workFolder) { value in
                    Task { @MainActor [weak self] in
                        if case .generating = self?.phase { self?.phase = .generating(value) }
                    }
                }
                let item = try library.addLivingPhoto(result, named: photo.deletingPathExtension().lastPathComponent, motion: motion)
                try? FileManager.default.removeItem(at: workFolder)
                phase = .choosing
                onDone(item)
            } catch {
                if let folder { try? FileManager.default.removeItem(at: folder) }
                if error as? LivingPhotoError == .cancelled || Task.isCancelled {
                    phase = preview == nil ? .choosing : .previewing
                } else {
                    phase = .failed(Self.describe(error))
                }
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        if case .generating = phase { phase = preview == nil ? .choosing : .previewing }
    }

    func reset() {
        cancel()
        photo = nil
        preview = nil
        phase = .choosing
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension LibraryModel {
    /// Moves a finished Living Photo out of its work folder into the library.
    func addLivingPhoto(_ result: LivingPhotoResult, named name: String, motion: LivingPhotoMotion) throws -> LibraryItem {
        let fm = FileManager.default
        try fm.createDirectory(at: location.mediaFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: location.thumbnailFolder, withIntermediateDirectories: true)
        let id = UUID()
        var item = LibraryItem(id: id, name: name.isEmpty ? "Living Photo" : name, kind: .livingPhoto,
                               media: "\(id.uuidString).mov", thumbnail: "\(id.uuidString).png", addedAt: Date())
        try fm.moveItem(at: result.video, to: location.mediaFolder.appendingPathComponent(item.media))
        do {
            try fm.moveItem(at: result.thumbnail, to: location.thumbnailURL(for: item))
        } catch {
            try? fm.removeItem(at: location.mediaFolder.appendingPathComponent(item.media))
            throw error
        }
        item.storedBytes = result.bytes
        add(item)
        return item
    }
}

/// The Living Photos in the library, and the way to make a new one.
struct LivingPhotosPage: View {
    @Environment(LibraryModel.self) private var library
    @Binding var selection: UUID?
    @State private var making = false

    var body: some View {
        let items: [LibraryItem] = library.items.filter { $0.kind == .livingPhoto }
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Bring a Photo to Life", systemImage: "person.and.background.dotted")
                } description: {
                    Text("Kinora lifts the subject off a still photo and lets it drift gently over its background, on your desktop and Lock Screen. Everything happens on your Mac, and your photo is left as it is.")
                } actions: {
                    Button("Choose a Photo…") { making = true }
                        .buttonStyle(.glassProminent)
                }
            } else {
                LibraryGrid(items: items, selection: $selection)
            }
        }
        .navigationSubtitle("Living Photos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Living Photo", systemImage: "wand.and.sparkles") { making = true }
                    .help("Turn a still photo into a living wallpaper")
            }
        }
        .sheet(isPresented: $making) {
            LivingPhotoSheet { item in
                selection = item.id
                making = false
            }
        }
    }
}

/// Choose a photo, see it move, pick how much, and make it.
struct LivingPhotoSheet: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var maker = LivingPhotoMaker()
    @State private var choosing = false
    @State private var dropTargeted = false
    let onDone: (LibraryItem) -> Void

    private var display: CGSize { VideoOptimizer.largestDisplayPixels() }

    var body: some View {
        VStack(spacing: 16) {
            stage
                .aspectRatio(display.width / max(1, display.height), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: .rect(cornerRadius: 12))
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    if dropTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 3) }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    maker.choose(url, display: display)
                    return true
                } isTargeted: { dropTargeted = $0 }

            controls
        }
        .padding(20)
        .frame(width: 640)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { maker.choose(url, display: display) }
        }
        .onDisappear { maker.reset() }
    }

    @ViewBuilder private var stage: some View {
        switch maker.phase {
        case .choosing:
            VStack(spacing: 10) {
                Image(systemName: "photo.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                Text("Drop a photo here").foregroundStyle(.secondary)
                Button("Choose a Photo…") { choosing = true }
            }
        case .preparing:
            ProgressView("Finding the subject…")
        case .previewing, .generating:
            if let preview = maker.preview {
                LivingPhotoPreview(renderer: preview, motion: maker.motion)
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
                Button("Choose Another Photo…") { choosing = true }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if maker.preview != nil, maker.phase != .preparing {
            Text(maker.subjectSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack {
            Picker("Motion", selection: $maker.motion) {
                ForEach(LivingPhotoMotion.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .disabled(maker.preview == nil || isGenerating)
            Spacer()
            if case .generating(let value) = maker.phase {
                ProgressView(value: value).frame(width: 140)
                    .accessibilityLabel("Making the Living Photo")
                Button("Stop") { maker.cancel() }
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Make Living Photo") {
                    maker.generate(into: library, display: display) { item in onDone(item) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(maker.phase != .previewing)
            }
        }
    }

    private var isGenerating: Bool {
        if case .generating = maker.phase { return true }
        return false
    }
}

/// The prepared photo, moving as it will on the desktop.
struct LivingPhotoPreview: View {
    let renderer: LivingPhotoRenderer
    let motion: LivingPhotoMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let seconds = renderer.plan.seconds
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: seconds) / seconds
            if let image = renderer.image(at: t) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
        }
        .accessibilityLabel("Preview of the Living Photo")
        .id(motion)
    }
}
