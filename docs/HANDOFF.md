# Continue Kinora

Updated: 2026-11-13, after a cloud session on branch `claude/gifted-darwin-0w9cpx`. Early development; no release yet.

## Audit at the start of this session

What the code held on `main` (4cdcf0c), checked against the design's milestones:

| Milestone | State found | Gaps found |
|---|---|---|
| 1 Foundation | Done | **CI on `main` was red**: Swift 6.3.3 timed out type-checking one expression in `ContentView`. The handoff's "71 tests pass" was from the owner's Mac (Swift 6.4.2). |
| 2 Vertical slice | Done | Initial activation restarts WallpaperAgent (known). Per-display untested. |
| 3 Library rules | Partial | Rotation only through *all* items (no playlists); schedule in the model and plug-in but no UI; Lock Screen/Dark pickers only while following Kinora's selection; the UI showed `rules.wallpaper`, not what rotation/schedule actually showed; removing an item used by Lock Screen, Dark, rotation or schedule left dangling IDs, and a System Settings tile naming a removed item drew a blank grey surface; no folders, images or GIFs; no Apple aerials. |
| Living Photos | Prototype only | Not in any target. |
| 4–7 | Not started | No shaders, format, gallery, Lively/WE parsing, onboarding, menu bar, intents, uninstall, diagnostics, updates or packaging. |

## What this session did

All on `claude/gifted-darwin-0w9cpx`, one commit per increment, each built and tested on GitHub's macOS 26 runner.

1. **CI fixed** and enabled for `claude/**` pushes and manual runs.
2. **Milestone 3.** Named playlists (timer or per unlock, optional shuffle that every process agrees on, Next); a time-of-day editor with a day-and-night preset; removal that says where an item is used and rewrites the rules first, refusing to remove the only thing showing; a plug-in fallback chain so a surface never goes blank; Apple aerials played in place from `~/Library/Application Support/com.apple.wallpaper/aerials/` (macOS 26) or the older `idleassetsd` folder, with read-only sandbox exceptions and never deleted; folder, picture and animated-GIF import; Pause All and Reduce Motion in the shared rules; a sidebar.
3. **Living Photos integrated.** Pure maths in `KinoraKit/LivingPhotos` (canvas, framing, motion, loop, fill sizes, texture transfer); `KinoraMedia` prepares layers with Vision + Core Image and encodes HEVC (H.264 fallback) with progress, cancellation and partial-output cleanup; a Living Photos section with a live preview, three motion strengths, and clear subject messages. Photos without a usable subject drift as one layer. The photo is only read. Refinement over the spike: subjects shorter than 84% of the crop are centred; taller ones keep the spike's top-aligned framing. The filled gap now grows with the motion so the subject's own pixels never show (tested).
4. **Milestone 4, Kinora Originals.** Live Sky (real sun from the time-zone table, NOAA equations, no Location Services), Aurora, Tide, Lava Lamp. `KinoraRender` compiles Metal source at run time. The plug-in's surface now holds video, still or shader content in one remote context with cross-fades. Originals draw only while playing, at their own rate capped by settings and battery, at 25–50% resolution, skipping frames rather than blocking. They appear in System Settings as their own group, and everywhere items do.
5. **Milestone 5.** [`docs/FORMAT.md`](FORMAT.md) (format v1: media and settings only, no code); strict validation of untrusted packages and zips; installer with in-place replacement; gallery client (explicit Browse, GitHub hosts only, no cookies/cache, streamed downloads with progress/cancel, size cap, SHA-256, listing must match); [`examples/aurora-rose`](../examples/aurora-rose); the separate gallery repository staged in [`gallery/`](../gallery/README.md) with an empty catalog.
6. **Milestone 6.** Lively (`LivelyInfo.json`, schema from Lively's GPL source) and Wallpaper Engine (`project.json`) folders and zips: videos, GIFs and pictures import; web, scenes, programs, streams and WebM get plain explanations. [WebM and WebKit evaluation](spikes/2026-11-13-webm-and-web-wallpapers.md) with the exact spike to run.
7. **Milestone 7.** Menu bar extra; three-step onboarding; Shortcuts actions and `kinora://` links on one shared state; Settings in tabs; manual (optionally weekly) update check that only links to releases; diagnostics export with no names or paths; Remove Kinora; `Tools/package-release.sh`, `Tools/uninstall.sh`, `Tools/measure-plugin.sh`; [INSTALL](INSTALL.md) (trust tradeoffs) and [BENCHMARKS](BENCHMARKS.md).

## Validation

**Observed** on GitHub's `macos-26` runner (virtual Apple-silicon Mac, Swift 6.3.3, SDK 26.5), every increment:

- `./build.sh test`: all tests pass, 140+ across KinoraKit and KinoraMedia (the KinoraKit subset also passes on Linux with Swift 6.3.3).
- `./build.sh` (universal release build and bundle assembly, ad hoc signed): succeeds.
- Living Photo pipeline end to end: synthetic photo, Vision found and lifted the subject, 30-frame loop of exact duration and size, last frame leads back to the first, cancellation removes partial output, non-photos refused, original untouched. Full-size release benchmark: 17.8–25.8 s for a 12 s 2940×1912 loop, 10.6 MB, 469–598 MB peak memory.
- All four shaders compile and draw non-flat, moving, deterministic images; Live Sky darkens at night. GPU per frame on the virtual GPU: 0.9–11.6 ms, noisy between runners, Aurora the costliest ([details](BENCHMARKS.md)).
- GIF conversion keeps frame timing; still GIFs are recognised.

**Not observed; assumptions until checked on a Mac:**

- Anything on screen: the app's new UI, the plug-in showing originals, stills, aerials and Living Photos on the desktop and Lock Screen, cross-fades, System Settings' Originals group, menu bar, onboarding.
- That `CAMetalLayer` content reaches WallpaperAgent through the remote `CAContext`, and that Metal works in the sandboxed plug-in.
- That the sandbox exceptions let the plug-in read the aerial folders and `/usr/share/zoneinfo`.
- That System Settings accepts the second tile group.
- Real-Mac CPU, GPU, energy and memory for any new path; Living Photo quality on real photos.
- Login item, update check against a real release, uninstall leaving no System Settings section, quarantined-download install.

**Observed limitation: Shortcuts actions.** The release build runs Apple's App Intents metadata extractor only for the library modules ("Extracted no relevant App Intents symbols") and produces no `Metadata.appintents` for the app, so the four actions in `Intents.swift` will not appear in Shortcuts yet. The `kinora://` links work without it (Shortcuts' "Open URLs"). Fixing it needs either an Xcode project for the app target or running `appintentsmetadataprocessor` by hand in `build.sh` with the compiler's const-values output.

## Owner checklists

Run on the Mac, then **restore your original wallpaper** (Settings › Advanced › Restore Original Wallpaper) at the end.

Build: `./build.sh test && ./build.sh install`, open `~/Applications/Kinora.app`.

**Library rules**
- [ ] Make a playlist of 3 items, play it every 15 minutes with shuffle; Next changes the desktop without a blink.
- [ ] Set a Lock Screen wallpaper different from the desktop; lock and unlock.
- [ ] Time of Day: Day and Night, then edit a time to 2 minutes from now; the desktop changes then.
- [ ] Remove an item used as the Lock Screen and in the playlist: the dialog lists both; afterwards both use another item. Try removing the only shown item: refused with a message.
- [ ] Apple Aerials: download one in System Settings, add it, use it. Remove it from Kinora: the aerial stays in System Settings.
- [ ] Drop a folder with videos and pictures, a still JPEG, an animated GIF.

**Living Photos** (use your own photos: a portrait, two or more people, a landscape, a pet with fur or hair edges)
- [ ] Preview appears in a second or two; motion strengths differ; subject message is right.
- [ ] Make one; progress moves; Stop cancels and leaves nothing in `~/Library/Application Support/Kinora/Work`.
- [ ] On the desktop and Lock Screen: no ghost of the subject in the gap, no visible loop point, no edges at full motion.
- [ ] `Tools/measure-plugin.sh 120 living-photo` while it plays (desktop clear, "Always moving"); compare with an ordinary video.

**Originals**
- [ ] Each original shows and moves on the desktop and Lock Screen; System Settings › Wallpaper has a "Kinora Originals" group.
- [ ] Live Sky matches the time of day where you are.
- [ ] Pause All, Reduce Motion and Low Power Mode hold the frame; "Rests while you work" settles after 5 s.
- [ ] `Tools/measure-plugin.sh 120 aurora` (and `sudo` once for energy).

**Packages, gallery, imports**
- [ ] Zip `examples/aurora-rose`, rename to `.kinorawallpaper`, double-click: installs as a tinted Aurora.
- [ ] Gallery › Browse: says the gallery isn't open yet (the repository doesn't exist).
- [ ] A Lively video wallpaper folder and a Wallpaper Engine video folder import; a WE scene and a Lively web wallpaper explain why not.

**App**
- [ ] Onboarding on first launch (`defaults delete io.github.sky-walkerx.kinora onboarded` to see it again).
- [ ] Menu bar: pause/resume, switch, playlist.
- [ ] `open kinora://pause`, `open kinora://resume` and `open kinora://next` work. (Shortcuts actions won't show yet; see above.)
- [ ] Open at login; Save Diagnostics produces a readable file with no names.
- [ ] Remove Kinora (without deleting the library): original wallpaper back, no Kinora section in System Settings after relaunching it. Reinstall with `./build.sh install` afterwards.

**Sleep, wake, displays**
- [ ] Sleep and wake with a video, an original and a Living Photo; no black frames.
- [ ] If an external display is available: both displays show and pause independently.

**Before any release** (not authorized yet)
- [ ] `Tools/package-release.sh`, copy the zip to another account or Mac via a download so it is quarantined, Open Anyway, and check the plug-in launches and the Lock Screen plays.

## Remaining work

- **Verify everything above on the Mac** and fix what fails. This session could not see the screen.
- Apply a selection without restarting WallpaperAgent (open since the spike).
- Per-display and per-Space choices (design §7.3).
- Run the WebKit-in-plug-in spike; decide on web wallpapers. Check `AVURLAsset` on WebM; build the Matroska/VP9 reader only if needed.
- Living Photos: test the real photo set; consider keeping a downscaled copy of the source to re-render at another size; reduce generation's peak memory (469 MB on CI).
- Gallery: choose and review the first footage with redistribution rights; publish `Sky-walkerX/kinora-gallery` **with the owner's approval**; until then the catalog stays empty.
- Sparkle 2 updates need an EdDSA key; decide with the owner. Today's checker only links to releases.
- Developer ID and notarization: decide with the owner ([options](INSTALL.md)); nothing bought, no signing material uploaded.
- Publish a release and the Homebrew tap only when the owner says go.
- Make the Shortcuts actions appear (App Intents metadata for the app target, see Validation).
- Localisation (String Catalogs), Reduce Transparency audit, VoiceOver pass on the new views.

## Development and verification

```sh
./build.sh test       # KinoraKit and KinoraMedia tests
./build.sh dev        # local debug app bundle
./build.sh            # universal release app bundle
Tools/package-release.sh   # release candidate in dist/, not published
```

Builds need macOS and Swift 6.2+. In a Linux cloud session, push to a `claude/**` branch: CI builds and tests on macOS 26 and prints the benchmarks. The KinoraKit tests also run on Linux with a Swift toolchain if `import CoreGraphics` is mapped to Foundation and `DesktopCoverage` is left out; CI is the authority.

The development Mac is Apple silicon on macOS 27.0.1. macOS 26, Intel, external displays, per-Space behaviour, reboot/pre-login behaviour and quarantined installs remain unverified; CI establishes none of them.

Keep native Swift/SwiftUI, GPL-3.0-or-later, no accounts, telemetry, paywalls or unsolicited networking. Private macOS interfaces need runtime checks and safe failures. Initial activation still restarts WallpaperAgent once; later choices following Kinora update live.

The owner authorized creating and pushing this repository and pushing development progress. That does not authorize a release, a gallery or tap repository, purchases, or uploading signing keys.

## Copyable continuation prompt

```text
Continue work on Sky-walkerX/kinora. Read README.md and docs/HANDOFF.md first;
the handoff lists what was built on branch claude/gifted-darwin-0w9cpx, what CI
observed, what is still an assumption, and the owner's on-device checklists.

Start from the checklist results the owner reports. Fix what fails on the Mac,
then continue with "Remaining work" in order. Keep GPL-3.0-or-later, native
Swift, local processing, no telemetry and no unsolicited network access. Add
tests for new logic and run ./build.sh test and ./build.sh on macOS (GitHub's
macOS CI from a Linux session). Record observed results separately from
assumptions in the handoff. Do not publish releases, create the gallery or tap
repositories, purchase anything or upload signing material without the
owner's explicit approval.
```
