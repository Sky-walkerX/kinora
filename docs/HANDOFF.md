# Continue Kinora

Updated: 2026-11-21, after a scheduled cloud session on branch `claude/gifted-darwin-5mxp6s`. Early development; no release yet.

## Where the work is

**`main` is behind.** It stops at the 2026-11-13 handoff (4cdcf0c). All later work is on `claude/gifted-darwin-5mxp6s`, which contains, unchanged, the earlier sessions' branches `claude/gifted-darwin-0w9cpx` (milestones 3 to 7, first pass) and `claude/gifted-darwin-cyae1h` (audit and fixes), plus this session's commits. Nothing has been merged or released.

Each scheduled run gets a new branch name and starts from `main`, and the stored task still describes `main`'s state. A run must check out the newest `claude/gifted-darwin-*` branch first, or it will redo finished work. This session found and fast-forwarded to `cyae1h` before changing anything. **Merging this branch into `main` (after the owner's review) ends that problem.**

## Audit at the start of this session (2026-11-21)

CI on the inherited state was green (macOS 26 runner, 197 tests). I read the code against the stored task's milestones; a separate read-only review of the library-rules code found nine defects, all checked against the code and fixed below.

| Milestone | Complete in code | Partial or missing | Fixed this session |
|---|---|---|---|
| 3 Library rules | Playlists (timer, unlock, shuffle), Lock Screen and Dark Mode variants, time-of-day editor, Apple aerials played in place, safe removal | Per-display and per-Space choices; on-device checks | See "What this session changed" 1 |
| Living Photos | Vision lift, framing, sideways fill and texture, HEVC loop; preview, motion strengths, progress, cancel, cleanup; evaluated on ten real photos on CI | Loop seam from encoding; real-Mac quality and power; hair strands, partial occlusion | Make Again for another display or motion (2); a measured pre-roll experiment for the seam (3) |
| 4 Originals | Live Sky, Aurora, Tide, Lava Lamp; previews, snapshots, power rules, System Settings group | Whether `CAMetalLayer` content reaches WallpaperAgent; real GPU cost | — |
| 5 Format and gallery | FORMAT.md v1, untrusted-package validation, in-process zip reader, installer, gallery client with downloads, progress, cancel, attribution; `gallery/` staged | First reviewed footage; publishing `kinora-gallery` needs the owner | — |
| 6 Lively / Wallpaper Engine | Video, GIF, picture import; clear refusals for web, scenes, programs, streams | WebKit-in-plug-in spike (needs a Mac) | WebM and Matroska conversion (4) |
| 7 Polish | Menu bar, onboarding, Shortcuts intents and `kinora://` links, settings, update check, diagnostics, uninstall, release scripts, INSTALL/BENCHMARKS | Sparkle, notarization (owner decisions); on-device checks; uninstall only restores the original when Kinora is on every display | App Intents metadata in the build (5) |

## What this session changed

1. **Library rules (milestone 3).**
   - Removing an item, editing or deleting a playlist, and Next acted on `selection.json` even after the user had restored their own wallpaper or picked another, so Kinora selected itself on every display and restarted WallpaperAgent. Housekeeping now updates the remembered rules without touching the store; Next, the "playing" marks and the removal dialog use the rules only while macOS shows them (`WallpaperController.liveRules`).
   - Use as Wallpaper, Play and Rotate replace the schedule, which had no other copy. The replaced schedule is remembered and the schedule editor offers **Restore Previous**.
   - The schedule editor silently kept one of two rows with the same start time. It now names the clash and disables Save until the times differ. Its times were an hour off on days the clocks change; fixed.
   - Adding or removing an item that wasn't on screen jumped a timed rotation to another wallpaper. `Rotation.changing(items:shuffle:interval:at:)` re-anchors it to keep the wallpaper on screen (or the next survivor), also for Shuffle and a new pace on a playing playlist. Unlock rotations keep their count, which only the plug-in knows.
   - Two-item shuffles often repeated a wallpaper; they alternate now.
   - The playlist page's Shuffle shows how the playlist is playing; the playlist editor lists originals.
   - An Apple aerial whose video macOS deleted froze on its thumbnail; plug-in and app now fall back as for a removed item (`LibraryLocation.showableItemIDs`).
   - A library index this version can't fully read (damaged, newer, entries skipped) is copied to `Backups/library-<hash>.json` before anything writes over it.
2. **Living Photos: Make Again.** Kinora keeps a copy of the photo (≤ 4096 px, upright, HEIC) with the item (`LivingPhotoSource`). The inspector offers Make Again with any motion, at the largest display's size, with progress and Stop. The item keeps its identity, so rules and playlists keep it. The user's photo is only read; removing the item removes the copy. Living Photos made before this have no copy and say so.
3. **Living Photos: loop seam experiment.** `LivingPhotoGenerator.encode(…, preroll:)` can encode the loop's last frames before the session start, so the encoder is warmed up at frame 0 and the edit list hides them. The evaluation workflow encodes each photo both ways and records both seams. Measured: too little gain to adopt (see Validation); the app doesn't use it.
4. **WebM and Matroska (milestone 6).** `MatroskaReader` (KinoraKit, pure Swift) and `MatroskaConverter` (KinoraMedia, VideoToolbox decode, HEVC encode) convert WebM and MKV once at import: VP9 (supplemental decoder), AV1 where the Mac has a decoder, H.264 and HEVC with B-frames. Direct files, folders, the file picker, Finder, and Lively/Wallpaper Engine wallpapers whose video is WebM, which were refused before. VP8 and undecodable AV1 are explained by name. Untrusted-input limits throughout. Details: [WebM spike notes](spikes/2026-11-13-webm-and-web-wallpapers.md).
5. **Shortcuts.** `Tools/app-intents-metadata.sh`, run by `build.sh` for every bundle, builds the app module once more with the compiler's constant values and runs Apple's `appintentsmetadataprocessor`, so the bundle gets `Metadata.appintents`. It notes and skips when any step is missing.

## Validation

**Observed on GitHub's `macos-26` runner** (virtual Apple-silicon Mac, Swift 6.3.3). Not a real Mac: no WallpaperAgent, no Lock Screen, paravirtual GPU, encoder and decoders.

- `./build.sh test`: **232 tests in 44 suites pass** (run 30, ca9296e), including the Matroska reader and converter and the rules fixes. `./build.sh` builds the universal release bundle and signs it ad hoc.
- **WebM and MKV conversion:** every fixture converts (`MatroskaConverterTests`): VP9 plain, live with unknown sizes, with superframes, 10-bit and with alpha, and H.264 and HEVC with B-frames, 10 frames and 1 s each, and every converted frame matches AVFoundation's decode of the HEVC reference more closely than its neighbours do, so colours, frames and order are right. VP8 is refused by name; a cut-off file keeps its whole frames; Stop leaves nothing. AV1 converts or is refused by name depending on the Mac (the runner reports an AV1 decoder).
- **Living Photo evaluation** on the ten real photos passed after this session's changes (runs on aeed3df and f8134a1). **Pre-roll measured and not adopted:** it lowered the loop seam only 2–15% for 5–15% more disk; the seam is mostly coding noise that the last and first frames can't share, about 1–2 luma levels of 255 ([numbers](BENCHMARKS.md#the-loop-seam-and-pre-roll-ci-2026-11-21-run-on-f8134a1)). Decoding a loop took 4.3–5.7% of one core on the virtual Mac.
- **App Intents metadata:** the build step is new in 35ea15f; whether CI's Xcode produced `Metadata.appintents`, and which actions it names, is printed in the "Build" step of the CI log.

- **An intermittent CI hang:** in one of four runs (run 33, on f8134a1, cancelled after 13 minutes), every test using VideoToolbox stalled at the same moment: the first WebM conversion, the container probe's HEVC decode, Living Photo and GIF encoding. Everything else passed. The cause isn't established; the likeliest is registering the supplemental VP9 decoder while other decoder and encoder sessions start, which the parallel tests did. Since then the decoder is registered once per process, by the app at launch, and `./build.sh test` runs tests one at a time, with a time limit on the conversion tests. If it recurs, look there first.

**Observed on Linux** (this session, Swift 6.3.3 for Linux, with a small CoreGraphics shim): the KinoraKit suites except window-coverage and ObjC-decoder tests compile and pass (174 tests). Useful for quick iteration only; not macOS evidence.

**Not observed; assumptions until checked on a Mac:** everything on screen (app UI, plug-in drawing videos, stills, aerials, originals and Living Photos on the desktop and Lock Screen, cross-fades, System Settings' tiles); real WebM files from Lively and the Workshop, long and 4K WebM conversions (time and memory), VP9 on Apple silicon's own decoder; that Shortcuts lists Kinora's actions and whether they run without a team-ID signature (other projects report they don't; `kinora://` links work regardless); that the unlock counter sees one unlock per lock on a multi-display Mac; that `CAMetalLayer` content reaches WallpaperAgent; sandbox access to the aerial folders; real CPU, GPU, energy and memory for every path; login item, update check against a real release, uninstall, quarantined installs.

## Owner checklists

Run on the Mac, then **restore your original wallpaper** (Settings › Advanced › Restore Original Wallpaper) at the end.

Build: `git checkout claude/gifted-darwin-5mxp6s && ./build.sh test && ./build.sh install`, open `~/Applications/Kinora.app`.

**Library rules**
- [ ] Make a playlist of 3 items, play it every 15 minutes with Shuffle; Next changes the desktop without a blink, and the grid's checkmark moves with it. Untick Shuffle while it plays: the desktop doesn't change.
- [ ] While a playlist plays, remove from it an item that isn't on screen: the desktop doesn't change.
- [ ] Play a playlist "Each Time You Unlock": lock and unlock three times; it steps once per unlock (with an external display too, if you have one). Relaunch Kinora, log out and in: it continues.
- [ ] Set a Lock Screen wallpaper different from the desktop; lock and unlock.
- [ ] Time of Day: Day and Night, edit a time to 2 minutes from now; the desktop and checkmark change then. Give two rows the same time: Save is disabled with a message. Then double-click another tile: the schedule ends; reopen the editor: **Restore Previous** brings it back.
- [ ] **Restore Original Wallpaper**, then remove a library item used in the old playlist, edit a playlist and use the menu bar: your own wallpaper stays and WallpaperAgent doesn't restart (no blink).
- [ ] Pick a Kinora tile in System Settings, then open Kinora: "Manage in Kinora" appears, and after it the variants do.
- [ ] Apple Aerials: add one, use it; delete it in System Settings: Kinora shows another wallpaper instead of a frozen still.

**Living Photos** (your own photos: a portrait, a group, a landscape, a pet)
- [ ] Preview in a second or two; motion strengths differ; the subject message is right.
- [ ] Make one; Stop cancels and leaves nothing in `~/Library/Application Support/Kinora/Work`.
- [ ] Inspector › Living Photo: change Motion, Make Again; the desktop switches to the new loop without going black, and playlists still include it.
- [ ] On the desktop and Lock Screen: no ghost of the subject in the gap, no visible loop point (watch the moment it restarts), no edges at full motion.
- [ ] `Tools/measure-plugin.sh 120 living-photo` (desktop clear, "Always moving"); compare with an ordinary video of the same size.

**WebM and MKV**
- [ ] Add a Lively WebM wallpaper (folder and zip) and a Wallpaper Engine video wallpaper whose file is WebM: both import and play. Note how long a 1080p and a 4K one take.
- [ ] Add a plain `.webm` and `.mkv` from Finder, by drag and through Add: they import. A VP8 WebM says it's VP8.

**Originals**
- [ ] Each shows and moves on the desktop and Lock Screen; System Settings › Wallpaper has a "Kinora Originals" group.
- [ ] Live Sky matches the time of day; Pause All, Reduce Motion and Low Power Mode hold the frame; "Rests while you work" settles after 5 s.
- [ ] `Tools/measure-plugin.sh 120 aurora` (and `sudo` once for energy).

**Packages, gallery, imports**
- [ ] Zip `examples/aurora-rose`, rename to `.kinorawallpaper`, double-click: installs as a tinted Aurora.
- [ ] Gallery › Browse: says the gallery isn't open yet (the repository doesn't exist).
- [ ] A Wallpaper Engine scene and a Lively web wallpaper explain why not.

**App, Shortcuts, sleep and displays**
- [ ] Shortcuts app: search "Kinora". Do Pause, Resume, Next and Set Desktop Motion appear? Do they run, or fail for lack of a team-ID signature? `open kinora://pause|resume|next` works either way.
- [ ] Onboarding (`defaults delete io.github.sky-walkerx.kinora onboarded`), menu bar, Open at Login, Save Diagnostics (no names in it).
- [ ] Sleep and wake with a video, an original and a Living Photo: no black frames.
- [ ] Remove Kinora (keep the library): original wallpaper back, no Kinora section in System Settings after relaunching it. Reinstall with `./build.sh install`.

**Before any release** (not authorized): `Tools/package-release.sh`, move the zip through a download so it is quarantined, Open Anyway, check the plug-in launches and the Lock Screen plays.

## Remaining work, in order

1. **Merge this branch** into `main` once the owner has looked at it, so scheduled runs start from it.
2. **On-device verification** with the checklists above; fix what fails.
3. Living Photos: look at the loop point on a real display. Pre-roll is measured and not worth it; if the seam shows, try a higher bitrate for Living Photos with the evaluation workflow. Measure real playback cost; if quality and power hold up, make Living Photos the headline feature (README, onboarding's first pick).
4. Apply a selection without restarting WallpaperAgent (open since the spike; initial activation still restarts it once).
5. Per-display and per-Space choices (design §7.3); uninstall should then also clear Kinora from displays, Spaces and the screen saver.
6. WebKit-in-plug-in spike (spike notes); decide on web wallpapers.
7. Gallery: choose and review the first footage; publish `Sky-walkerX/kinora-gallery` **only with the owner's approval**.
8. Sparkle 2 needs an EdDSA key, and Developer ID/notarization a paid account (which Shortcuts may also need): decide with the owner ([options](INSTALL.md)). Nothing bought, no signing material uploaded.
9. Localisation (String Catalogs), Reduce Transparency audit, VoiceOver pass.

## Development and verification

```sh
./build.sh test       # KinoraKit and KinoraMedia tests
./build.sh dev        # local debug app bundle (also writes App Intents metadata)
./build.sh            # universal release app bundle
Tools/package-release.sh   # release candidate in dist/, not published
```

Builds need macOS and Swift 6.2+. A Linux cloud session has no Swift toolchain by default: push to a `claude/**` branch and read GitHub's macOS CI ("CI", and "Living Photo evaluation" for pushes touching Living Photo code, whose artifact holds frames and `metrics.json`). For quicker KinoraKit checks on Linux, Swift for Linux works with a module named `CoreGraphics` that re-exports Foundation (plus an empty `_Testing_CoreGraphics`), leaving out `DesktopCoverage.swift`, `PowerTests.swift`, `AppleWallpaperDecoder.swift` and `SettingsViewModelTests.swift`. CI is never evidence of on-screen, Lock Screen, power or multi-display behaviour.

Keep native Swift/SwiftUI, GPL-3.0-or-later, no accounts, telemetry, paywalls or unsolicited networking. Private macOS interfaces need runtime checks and safe failures. The owner authorized pushing development progress to this repository; that does not authorize a release, a gallery or tap repository, purchases, or uploading signing keys.

## Copyable continuation prompt

```text
Continue work on Sky-walkerX/kinora. Check out the newest claude/gifted-darwin-*
branch (claude/gifted-darwin-5mxp6s as of 2026-11-21), or main if it has been
merged, and read README.md and docs/HANDOFF.md: it lists what is built, what CI
observed, what is still an assumption, and the owner's on-device checklists.
Start from any checklist results the owner reports, fix what fails, then
continue "Remaining work" in order. Keep GPL-3.0-or-later, native Swift, local
processing, no telemetry and no unsolicited network access. Add tests for new
logic; run ./build.sh test and ./build.sh on macOS (GitHub's macOS CI from
Linux). Record observed results separately from assumptions. Do not publish
releases, create the gallery or tap repositories, purchase anything or upload
signing material without the owner's explicit approval.
```
