# Continue Kinora

Updated: 2026-11-22, after a scheduled cloud session on branch `claude/gifted-darwin-ez86sy`. Early development; no release yet.

## Where the work is

**`main` is behind.** It stops at the 2026-11-13 handoff (4cdcf0c). All later work is one linear chain of session branches, each containing the previous one unchanged:

`claude/gifted-darwin-0w9cpx` → `claude/gifted-darwin-cyae1h` → `claude/gifted-darwin-5mxp6s` → **`claude/gifted-darwin-ez86sy`** (newest: everything, plus this session).

Each scheduled run gets a new branch name, starts from `main`, and is handed the stored task, which still describes `main`'s state. A run must check out the newest `claude/gifted-darwin-*` branch first or it redoes finished work; this session fast-forwarded to `5mxp6s` before changing anything. **Merging `claude/gifted-darwin-ez86sy` into `main`, after the owner's review, ends this.** Nothing has been merged or released.

## Audit at the start of this session (2026-11-22)

CI on the inherited state was green on this branch (run 36 on ab7c035, macOS 26 runner). Compared with the stored task's milestones:

| Milestone | Complete in code | Partial or missing | This session |
|---|---|---|---|
| 3 Library rules | Playlists (timer, unlock, shuffle), Lock Screen and Dark Mode variants, time-of-day editor, Apple aerials in place, safe removal, disk-light conversion, battery-first defaults | Per-Space choices; on-device checks | **Per-display wallpapers** (1) |
| Living Photos | Vision lift, framing, sideways fill and texture, HEVC loop; preview, motion, progress, cancel, cleanup, Make Again; ten real photos on CI | Real-Mac quality, loop point and power; headline decision waits on them | Preview honours Reduce Motion (3) |
| 4 Originals | Live Sky, Aurora, Tide, Lava Lamp; previews, snapshots, power rules, System Settings group | Whether `CAMetalLayer` content reaches WallpaperAgent; real GPU cost | — |
| 5 Format and gallery | FORMAT.md v1, untrusted-package validation, in-process zip reader, installer, gallery client; `gallery/` staged locally | First reviewed footage; publishing `kinora-gallery` needs the owner | — |
| 6 Lively / Wallpaper Engine | Video, GIF, picture, WebM and MKV import; clear refusals for web, scenes, programs, streams | WallpaperAgent half of the WebKit spike | **WebKit sandbox probe on CI** (2) |
| 7 Polish | Menu bar, onboarding, Shortcuts intents and metadata, `kinora://` links, settings, update check, diagnostics, uninstall, release scripts, INSTALL/BENCHMARKS | Sparkle and notarization (owner decisions); on-device checks; localisation | VoiceOver and Reduce Transparency fixes (3) |

## What this session changed

1. **Per-display wallpapers (milestone 3, design §7.3).** `KinoraSelection.displays` holds a fixed `DisplayChoice` per display (desktop item, optional own Lock Screen, the display's name for when it's disconnected), keyed by the display's UUID (`CGDisplayCreateUUIDFromDisplayID`, stable across reboots). The plug-in maps each surface's `directDisplayID` to that key and resolves it with `SurfaceResolution` as before, so a display's choice needs **no store write and no WallpaperAgent restart**. Unknown displays, and older plug-ins, show the main rules.
   - App: tiles get **Use on Display ›** (each display, All Displays) when more than one display is connected; the inspector's **Displays** section sets each display's wallpaper and Lock Screen or "Same as Other Displays", and lists choices for disconnected displays with Forget. Checkmarks mark items shown on any display.
   - Rules: rotations, schedules and Dark Mode stay with the main rules; Use as Wallpaper keeps display choices (like the Lock Screen and Dark Mode variants); All Displays clears them. Removing an item takes it off every display first, and the removal dialog says "a display's own wallpaper". Diagnostics count display choices.
   - Per-Space choices remain missing: the plug-in isn't told which Space a surface is for, so they need distinct per-Space store entries (see Remaining work).
2. **WebKit-in-plug-in spike, sandbox half (milestone 6).** `docs/spikes/2026-11-22-webkit-probe/` and the "WebKit probe" workflow: a probe app signed exactly as the plug-in is (plus a network variant and an unsandboxed one) loads a local page from Kinora's library folder in six ways — visible, hidden, hidden with WebKit's occlusion switch off, far off screen, and two re-hosted through a remote `CAContext` shown by a `CALayerHost` in a window of its own — and measures loading, animation rates, visibility and whether re-hosted pixels arrive and move. Results: see Validation and [the spike notes](spikes/2026-11-13-webm-and-web-wallpapers.md#web-wallpapers-the-webkit-in-plug-in-spike).
3. **Accessibility.** Library tiles had only mouse gestures; VoiceOver now gets a button trait, select as the default action and a "Use as Wallpaper" action. Living Photo previews hold still with Reduce Motion, as the originals' previews already did. Tile badges are more opaque with Reduce Transparency. Decorative thumbnails and icons are hidden from VoiceOver.

## Validation

**Observed on GitHub's `macos-26` runner** (virtual Apple-silicon Mac, macOS 26.7.2, Swift 6.3.3). Not a real Mac: no Lock Screen session to test, paravirtual GPU, encoder and decoders, one virtual display.

- `./build.sh test`: **248 tests in 47 suites pass**, one at a time, in 27 s (CI run 38, 5265937), including 11 new per-display tests (`DisplayChoiceTests`). `./build.sh` builds and signs the universal release bundle with the per-display code in the app and plug-in; the release-mode Living Photo benchmark still passes. The first per-display push (run 37) failed to compile the plug-in (an os_log interpolation needed `self`); fixed in dede826.
- **WebKit probe** (runs 1 and 2, macOS 26.7.2 runner): with the plug-in's exact entitlements WebKit's WebContent process ends on every load; with `network.client` added (or no sandbox) the page loads. In any window nobody can see, the page stops (0 animation frames, CSS frozen, timers about 2.5/s), even with WebKit's switches for hidden pages; in a window ordered in **off every display with WebKit's occlusion switch off** it runs at full rate (51–53 frames/s) and reports itself visible, and its layers moved into a remote `CAContext` arrive, moving, in a `CALayerHost` elsewhere. [Table and caveats](spikes/2026-11-13-webm-and-web-wallpapers.md#sandbox-half-run-on-ci-2026-11-22).
- Earlier sessions' CI observations still hold for code this session didn't touch: WebM and MKV conversion of every VP9, H.264 and HEVC fixture (frames and order checked against an HEVC reference; AV1 untested on CI), App Intents metadata in the bundle, the ten-photo Living Photo evaluation, originals at 1.0–3.5 ms GPU per frame on the virtual GPU. See [BENCHMARKS](BENCHMARKS.md).
- The intermittent VideoToolbox stall seen once in run 33 did not recur in runs 34–38 (tests run one at a time since 09ddcb0).

**Observed on Linux** (this session, Swift 6.3.3 for Linux with a `CoreGraphics` shim): 185 KinoraKit tests pass, including the per-display ones. Quick iteration only; not macOS evidence.

**Not observed; assumptions until checked on a Mac:**
- Per-display: that WallpaperAgent's `directDisplayID` is the `CGDirectDisplayID` (the plug-in already relies on this for coverage), that `CGDisplayCreateUUIDFromDisplayID` works inside the plug-in's sandbox (if it doesn't, every display shows the main rules, and the log says `display=unknown`), and that each display's desktop and Lock Screen surfaces show their own choice. Only one display was ever available to test.
- Everything on screen (app UI, plug-in drawing every kind of wallpaper on the desktop and Lock Screen, cross-fades, System Settings tiles); real WebM files and long or 4K conversions; Shortcuts listing and running Kinora's actions without a team-ID signature; the unlock counter on a multi-display Mac; `CAMetalLayer` content reaching WallpaperAgent; sandbox access to the aerial folders; real CPU, GPU, energy and memory for every path; login item, update check, uninstall, quarantined installs; VoiceOver actually announcing the new tile actions.

## Owner checklists

Run on the Mac, then **restore your original wallpaper** (Settings › Advanced › Restore Original Wallpaper) at the end.

Build: `git checkout claude/gifted-darwin-ez86sy && ./build.sh test && ./build.sh install`, open `~/Applications/Kinora.app`.

**Displays** (needs a second display)
- [ ] With two displays, right-click a tile › Use on Display › the external one: only that display changes, with no blink; the other keeps its wallpaper. The inspector's Displays section shows the choice.
- [ ] Give that display its own Lock Screen; lock: each display shows its own Lock Screen. Unlock.
- [ ] Play a playlist: the display with its own wallpaper doesn't rotate. Remove its item from the library: that display goes back to the others' wallpaper.
- [ ] Unplug the display: the Displays section lists it as not connected; plug it back in: it shows its wallpaper again. Forget clears it.
- [ ] `log stream --predicate 'subsystem == "io.github.sky-walkerx.kinora"' | grep acquire` shows `display=<UUID>`, not `display=unknown`.

**Library rules**
- [ ] Make a playlist of 3 items, play it every 15 minutes with Shuffle; Next changes the desktop without a blink, and the grid's checkmark moves with it. Untick Shuffle while it plays: the desktop doesn't change.
- [ ] While a playlist plays, remove from it an item that isn't on screen: the desktop doesn't change.
- [ ] Play a playlist "Each Time You Unlock": lock and unlock three times; it steps once per unlock (with an external display too). Relaunch Kinora, log out and in: it continues.
- [ ] Set a Lock Screen wallpaper different from the desktop; lock and unlock.
- [ ] Time of Day: Day and Night, edit a time to 2 minutes from now; the desktop and checkmark change then. Give two rows the same time: Save is disabled with a message. Then double-click another tile: the schedule ends; reopen the editor: **Restore Previous** brings it back.
- [ ] **Restore Original Wallpaper**, then remove a library item used in the old playlist, edit a playlist and use the menu bar: your own wallpaper stays and WallpaperAgent doesn't restart (no blink).
- [ ] Pick a Kinora tile in System Settings, then open Kinora: "Manage in Kinora" appears, and after it the variants do.
- [ ] Apple Aerials: add one, use it; delete it in System Settings: Kinora shows another wallpaper instead of a frozen still.

**Living Photos** (your own photos: a portrait, a group, a landscape, a pet)
- [ ] Preview in a second or two; motion strengths differ; the subject message is right. With Reduce Motion on, the preview holds still.
- [ ] Make one; Stop cancels and leaves nothing in `~/Library/Application Support/Kinora/Work`.
- [ ] Inspector › Living Photo: change Motion, Make Again; the desktop switches to the new loop without going black, and playlists still include it.
- [ ] On the desktop and Lock Screen: no ghost of the subject in the gap, no visible loop point (watch the moment it restarts), no edges at full motion.
- [ ] `Tools/measure-plugin.sh 120 living-photo` (desktop clear, "Always moving"); compare with an ordinary video of the same size.

**WebM and MKV**
- [ ] Add a Lively WebM wallpaper (folder and zip) and a Wallpaper Engine video wallpaper whose file is WebM: both import and play. Note how long a 1080p and a 4K one take.
- [ ] Add a plain `.webm` and `.mkv` from Finder, by drag and through Add: they import. A VP8 WebM says it's VP8. An AV1 WebM converts on an M3 or later Mac and says this Mac can't decode AV1 on older ones.

**Web wallpapers (spike, nothing is promised)**
- [ ] `docs/spikes/2026-11-22-webkit-probe/run.sh` on the Mac: two small windows appear for about a minute; it prints one line per scenario. Compare with CI's (spike notes). It changes no settings.

**Originals**
- [ ] Each shows and moves on the desktop and Lock Screen; System Settings › Wallpaper has a "Kinora Originals" group.
- [ ] Live Sky matches the time of day; Pause All, Reduce Motion and Low Power Mode hold the frame; "Rests while you work" settles after 5 s.
- [ ] `Tools/measure-plugin.sh 120 aurora` (and `sudo` once for energy).

**Packages, gallery, imports**
- [ ] Zip `examples/aurora-rose`, rename to `.kinorawallpaper`, double-click: installs as a tinted Aurora.
- [ ] Gallery › Browse: says the gallery isn't open yet (the repository doesn't exist).
- [ ] A Wallpaper Engine scene and a Lively web wallpaper explain why not.

**App, accessibility, Shortcuts, sleep**
- [ ] VoiceOver: on a library tile, VO-Space selects it and the Actions rotor offers "Use as Wallpaper".
- [ ] Shortcuts app: search "Kinora". Do Pause, Resume, Next and Set Desktop Motion appear and run? `open kinora://pause|resume|next` works either way.
- [ ] Onboarding (`defaults delete io.github.sky-walkerx.kinora onboarded`), menu bar, Open at Login, Save Diagnostics (no names in it; it counts display choices).
- [ ] Sleep and wake with a video, an original and a Living Photo: no black frames.
- [ ] Remove Kinora (keep the library): original wallpaper back, no Kinora section in System Settings after relaunching it. Reinstall with `./build.sh install`.

**Before any release** (not authorized): `Tools/package-release.sh`, move the zip through a download so it is quarantined, Open Anyway, check the plug-in launches and the Lock Screen plays.

## Remaining work, in order

1. **Merge `claude/gifted-darwin-ez86sy` into `main`** once the owner has looked at it, so scheduled runs start from it.
2. **On-device verification** with the checklists above; fix what fails.
3. Living Photos: look at the loop point on a real display; measure real playback cost. If quality and power hold up, make Living Photos the headline feature (README, onboarding's first pick). Pre-roll is measured and not worth it; a higher bitrate is the next thing to try if the seam shows.
4. Apply a selection without restarting WallpaperAgent (open since the spike; initial activation still restarts it once). Per-display choices already avoid it after activation.
5. Web wallpapers: **owner decision first** — WebKit needs `com.apple.security.network.client`, which the plug-in lacks on purpose. Recommended, if wanted: a second, web-only wallpaper plug-in with that entitlement, every non-file load blocked (`WKContentRuleList`, non-persistent data store), an off-screen ordered-in window with occlusion detection off, its layers in the remote context, and ordering out as the pause. Then the on-Mac steps of the spike: can an ExtensionKit plug-in order in a window, does WallpaperAgent show it on the desktop and Lock Screen, what WebContent and GPU cost. Keep refusing web wallpapers until then.
6. Per-Space choices: the plug-in isn't told which Space a surface is for, so each Space needs its own store entry with its own configuration (for example `followsKinora` plus a Space key in `ChoiceConfiguration`, and `KinoraSelection.spaces`). The Space UUIDs are the store's `Spaces` keys; naming them "Desktop 1, 2…" needs the private `CGSCopyManagedDisplaySpaces`. Every change is a store write and a WallpaperAgent restart, so verify on hardware before building UI. Uninstall must then clear those entries too.
7. Gallery: choose and review the first footage; publish `Sky-walkerX/kinora-gallery` **only with the owner's approval**.
8. Sparkle 2 needs an EdDSA key, and Developer ID/notarization a paid account (which Shortcuts may also need): decide with the owner ([options](INSTALL.md)). Nothing bought, no signing material uploaded.
9. Localisation (String Catalogs; SwiftPM's command-line build would need the catalog compiled in `build.sh`), keyboard navigation of the library grid, a full VoiceOver pass on a Mac.

## Development and verification

```sh
./build.sh test       # KinoraKit and KinoraMedia tests
./build.sh dev        # local debug app bundle (also writes App Intents metadata)
./build.sh            # universal release app bundle
Tools/package-release.sh   # release candidate in dist/, not published
docs/spikes/2026-11-22-webkit-probe/run.sh   # WebKit sandbox probe
```

Builds need macOS and Swift 6.2+. A Linux cloud session has no Swift toolchain by default: push to a `claude/**` branch and read GitHub's macOS CI ("CI"; "Living Photo evaluation" for Living Photo code, with frames and `metrics.json` as an artifact; "WebKit probe" for the probe). For quicker KinoraKit checks on Linux, Swift for Linux (download.swift.org, 6.3.3) works with a module named `CoreGraphics` that re-exports Foundation (plus an empty `_Testing_CoreGraphics`), leaving out `DesktopCoverage.swift`, `PowerTests.swift`, `AppleWallpaperDecoder.swift` and `SettingsViewModelTests.swift`, and with `Tests/Fixtures`, `examples` and `gallery` linked beside it. CI is never evidence of on-screen, Lock Screen, power or multi-display behaviour.

Keep native Swift/SwiftUI, GPL-3.0-or-later, no accounts, telemetry, paywalls or unsolicited networking. Private macOS interfaces need runtime checks and safe failures. The owner authorized pushing development progress to this repository; that does not authorize a release, a gallery or tap repository, purchases, or uploading signing keys.

## Copyable continuation prompt

```text
Continue work on Sky-walkerX/kinora. Check out the newest claude/gifted-darwin-*
branch (claude/gifted-darwin-ez86sy as of 2026-11-22), or main if it has been
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
