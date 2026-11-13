// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import KinoraKit
import KinoraRender
import SwiftUI

/// Three short steps on first launch: what Kinora is and why macOS asked about it, switching on
/// the plug-in, and a first wallpaper that needs no download.
struct OnboardingView: View {
    @Environment(WallpaperController.self) private var wallpaper
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarded") private var onboarded = false
    @State private var step = 0
    @State private var choice: UUID? = KinoraOriginals.all.first?.id

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch step {
            case 0: welcome
            case 1: plugIn
            default: firstWallpaper
            }
            Spacer(minLength: 0)
            HStack {
                Text("Step \(step + 1) of 3").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < 2 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip") { finish() }
                    Button("Use This Wallpaper") {
                        if let choice { Task { await wallpaper.use(itemID: choice) } }
                        finish()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil || wallpaper.plugIn != .enabled)
                }
            }
        }
        .padding(28)
        .frame(width: 560, height: 470)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Welcome to Kinora").font(.largeTitle.bold())
            Text("Kinora puts moving wallpapers on your desktop and Lock Screen. macOS itself draws them, through a wallpaper plug-in like the one Apple's aerials use, so they keep playing after you quit Kinora.")
            Text("By default the desktop rests while you work: it moves on the Lock Screen, for a few seconds after you unlock, and when your desktop is clear, then holds still. That uses the least battery. You can change it in Settings.")
                .foregroundStyle(.secondary)
            GroupBox {
                Text("Kinora is free software that isn't notarized by Apple, so the first time you opened it macOS asked you to approve it in System Settings › Privacy & Security. That approval is all it needs. Kinora has no account, no ads and no tracking, and only goes online when you browse the gallery or check for updates.")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var plugIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch On the Plug-in").font(.title.bold())
            Text("macOS lists Kinora's wallpapers in System Settings › Wallpaper once its plug-in is switched on. Kinora does this for you and checks it every time it starts.")
            HStack(spacing: 10) {
                switch wallpaper.plugIn {
                case .enabled:
                    Label("The plug-in is on.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .unknown:
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                case .disabled, .missing:
                    Label("macOS has the plug-in switched off.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Turn On") { Task { await wallpaper.repairPlugIn() } }
                }
            }
            .padding(.vertical, 6)
            Text("The first time Kinora becomes your wallpaper, macOS's wallpaper service restarts once, so your screen may blink. After that, changes appear without a blink. Restore Original Wallpaper puts back what you had.")
                .foregroundStyle(.secondary)
        }
    }

    private var firstWallpaper: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a First Wallpaper").font(.title.bold())
            Text("Kinora Originals are drawn live on your Mac and need no download. You can add your own videos and photos, and turn photos into Living Photos, any time.")
            if OriginalRenderer.shared == nil {
                Text("This Mac's graphics don't support Metal, so add a video of your own instead.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(KinoraOriginals.all) { original in
                        Button { choice = original.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                OriginalPreview(original: original)
                                    .clipShape(.rect(cornerRadius: 8))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(choice == original.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 3)
                                    }
                                Text(original.name).font(.callout)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(choice == original.id ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func finish() {
        onboarded = true
        dismiss()
    }
}
