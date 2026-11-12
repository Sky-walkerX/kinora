# Continue Kinora

Updated: 2026-11-13. This repository is an early development snapshot, with no release yet.

## Current state

Kinora is a native Swift macOS live wallpaper app, GPL-3.0-or-later. The app manages a local video library; an ExtensionKit wallpaper plug-in renders through WallpaperAgent on the desktop and Lock Screen. The app can quit while the plug-in keeps playing.

Implemented in the main targets:

- Video import with thumbnails, rename and removal; conversion to display-sized HEVC when it saves space, with savings shown in the UI.
- Wallpaper selection, original wallpaper backup and restore, plug-in registration repair, and monitoring for changes made by System Settings.
- Live selection changes after Kinora is selected, Lock Screen and dark appearance variants, and automatic rotation. Time-of-day scheduling exists in the shared rules model but has no editing UI yet.
- Battery-first playback defaults, coverage and power rules, and a plug-in CPU/energy readout.
- Shared logic tests and a GitHub Actions build/test workflow.

The latest work is a **Living Photos prototype**, outside the app targets. It lifts a foreground subject using Vision, fills the background with sideways colour sampling and transferred texture, then renders subtle parallax into a seamless HEVC loop. It is not integrated into the app. Start with [the spike report](spikes/2026-11-12-living-photos-spike.md) and [the prototype](spikes/2026-11-12-living-photos/livingphoto.swift). The latest prototype uses reduced motion and texture fill; the report's first approach describes an earlier iteration.

## Read first

- [README](../README.md): build and requirements.
- [Design and original milestones](superpowers/specs/2026-11-12-kinora-design.md): product constraints and architecture. It contains historical plans, not a completion checklist.
- [Lock Screen spike](spikes/2026-11-12-lock-screen-spike.md): private protocol and evidence.
- [Competitor research](research/2026-11-12-competitor-gaps.md): historical research behind Living Photos, battery-first defaults and smaller imports.

## Suggested next task

Integrate Living Photos into the native app. Move the useful prototype logic into maintainable code, add photo selection and a preview/generation flow, and save the generated video through the existing library and playback path. Avoid re-encoding the generated loop unnecessarily. Add progress, cancellation, clear errors and cleanup of partial output. Handle photos without a usable foreground mask and preserve the original photo. Test framing and motion calculations, loop boundaries, and failure/cancellation behavior.

The prototype has force unwraps, fixed dimensions, synchronous loops and debug-image output; do not ship it unchanged. Validate portraits, multiple subjects, landscapes and narrow images before making quality claims. Use only fixtures that may be redistributed.

Remaining original milestones include Apple aerial import, schedule editing, per-display/per-Space controls, shader wallpapers, a gallery, Lively/Wallpaper Engine imports, onboarding, uninstall, accessibility, benchmarks and release packaging. They are not all implemented by this snapshot.

## Development and verification

```sh
./build.sh test       # shared logic tests
./build.sh dev        # local debug app bundle
./build.sh            # universal release app bundle
```

Builds require macOS and the Swift/Xcode toolchain (Swift tools version 6.2 or later). A Linux cloud environment can edit and review the source but cannot build or run the macOS app. Use GitHub Actions for the existing macOS build/test checks and the owner's Mac for visual and Lock Screen verification.

The development machine was Apple silicon on macOS 27.0.1. macOS 26, Intel, external displays, per-Space behavior, reboot/pre-login behavior and quarantined downloaded installs remain unverified. CI does not establish those behaviors. On-device sessions that change wallpaper settings must restore the owner's originals at the end.

Keep native Swift/SwiftUI, GPL-3.0-or-later, no accounts, telemetry, paywalls or unsolicited networking. The wallpaper integration uses private macOS interfaces, so preserve runtime checks and safe failures. Initial activation still restarts WallpaperAgent once; subsequent choices following Kinora update live. Do not claim quiet initial activation is solved.

The owner authorized creating and pushing this public repository on 2026-11-13. This does not authorize a release, signing-key upload or Homebrew publication.

## Copyable continuation prompt

```text
Continue work on Sky-walkerX/kinora. Read README.md, docs/HANDOFF.md,
docs/superpowers/specs/2026-11-12-kinora-design.md, and the Living Photos
spike report and prototype linked from the handoff. Inspect the current
source before deciding what is complete.

The next task is to integrate Living Photos into the native SwiftUI app:
select a still photo, preview subtle parallax, generate a seamless HEVC
loop with progress/cancellation, and add it to the existing library and
wallpaper playback path. Preserve the latest prototype's reduced motion,
subject framing, sideways colour fill and texture transfer. Handle absent
subjects, errors and partial-output cleanup. Preserve existing libraries,
wallpaper backup/restore, power rules and live selection behavior.

Keep GPL-3.0-or-later, native Swift, local processing, no telemetry and no
unsolicited network access. Add meaningful tests for new logic and run
./build.sh test and ./build.sh dev on macOS. If the cloud environment is
Linux, use GitHub's macOS CI and state which on-device checks remain.
Update the handoff with actual results. Implement and verify the work;
do not publish a release or upload signing material.
```
