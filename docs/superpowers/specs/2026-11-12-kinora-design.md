# Kinora design

Status: draft for the owner's approval. Date: 2026-11-12.

Kinora is a native, free, GPL-3.0-or-later live wallpaper app for macOS. It is meant to be the Mac answer to Lively Wallpaper, which is Windows-only and has about 20k GitHub stars. The UI should feel like Apple made it. The name comes from the Kinora, an 1890s home viewer for moving pictures. The name is clear on GitHub, Homebrew and the Mac App Store.

Who decided what:

- **Owner:** the name, the license, native Swift only, no telemetry, no paid Developer ID, distribution through GitHub releases and Homebrew, and approval before any public repo or release.
- **Claude, with the owner's approval of the direction:** the product calls below. The owner handed those over ("you should decide it"). Calls marked *(Claude's call)* were not discussed in detail and can be changed.

Background:
- Lock Screen spike: [`docs/spikes/2026-11-12-lock-screen-spike.md`](../../spikes/2026-11-12-lock-screen-spike.md)
- Competitor and user-needs research: section 2

## 1. Why this exists

Mac users who want a moving desktop today have three choices:

- **Paid apps:** Backdrop at $29.99 lifetime or $1.99/month, Wallper at $9.99 to $14.99, Wallspace, Vivid Walls, Narwall.
- **Source-available:** Muro (512 stars, PolyForm Shield license, so not open source in the usual sense).
- **Small or abandoned open-source projects.** Plash closed its source. wallpaper-player-mac has no license and no commits since January 2025.

There is no trustworthy, actively built, truly open-source option. Kinora fills that gap. It is a reputation project, not a business.

**What success looks like** *(Claude's call)*:

- People who already use Muro or a paid app switch because Kinora is:
  - more trustworthy
  - measurably lighter
  - free of glitches
  - capable of more than video
- Its battery claims hold up in published, reproducible measurements.
- It becomes the app people recommend when someone asks "Wallpaper Engine for Mac?"

## 2. What people need

From GitHub issues (Muro, Plash, Lively, wallpaper-player-mac) and six Reddit launch threads (Backdrop, Wallper, Muro, Vivid Walls, WallFlow), most frequent first:

1. **Battery and CPU.**
   - Asked in nearly every thread: "burnt by the other MacOS wallpaper apps using 70% of my cpu and draining my battery in 2 hours."
   - Developers answer with unverified "<1% CPU".
2. **A Lock Screen that behaves like Apple's.**
   - People want it to play while locked and settle on unlock.
   - They want a different wallpaper on the Lock Screen than on the desktop, per display.
   - Muro's Lock Screen breaks often: issues #11, #44 and #58, plus a Reddit report.
3. **Seamless loops.** People reported a flicker or black flash at the loop point five times.
4. **Trust.**
   - Reddit treats new wallpaper apps as "slop apps with AI posts" and "1:1 clones".
   - Muro changed its license after announcing MIT.
   - Backdrop left a System Settings entry that a user could not remove after uninstalling.
5. **Easy install.** Gatekeeper warnings confuse people, and they ask for Homebrew.
6. **Content to browse,** including ultrawide.
7. **Wallpaper Engine content on a Mac.**
8. **Rotation and automation:** day and night, shuffle, weather.
9. **More than video:** shaders, music-reactive and interactive wallpapers.
10. **Whether the app has to stay open.** Users ask, and for Muro and Wallper the answer is yes.

## 3. Goals for v1

1. **Live wallpaper on the desktop, Lock Screen and screen saver, on every display.** It renders through macOS's own wallpaper system, so it feels built in.
2. **Kinora wallpapers show up in System Settings › Wallpaper,** next to Apple's, and can be picked there as well as in Kinora.
3. **The app can quit, and the wallpaper keeps playing,** because macOS runs the renderer.
4. **Provably light:**
   - a live energy readout in the app
   - power rules the user controls
   - published, reproducible benchmarks against Muro, Backdrop and Wallper
5. **No glitches:** gapless loops, no black frames when a surface is created, and a Lock Screen setup that checks and repairs itself.
6. **Content:**
   - Kinora's own Metal shader wallpapers, built in
   - a curated gallery of footage we may legally redistribute
   - the user's own videos, images and GIFs
   - Lively and Wallpaper Engine video and web wallpapers the user owns
   - Apple aerials already downloaded on the Mac
7. **Variants:**
   - light and dark variants
   - a time-of-day schedule
   - a different wallpaper for the Lock Screen and the desktop
   - per display and per Space
8. **Apple-quality UI:**
   - a SwiftUI main window
   - Settings that follows the Human Interface Guidelines
   - a menu bar extra
   - App Intents and Shortcuts
   - onboarding
9. **Clean install, update and uninstall.** Uninstalling leaves no trace, including in System Settings.

## 4. Not in v1

Possible later:

- Wallpaper Engine "scene" wallpapers, which need a renderer of their own
- music-reactive wallpapers *(Claude's call: v1.x, after the core is solid)*
- interactive wallpapers that react to clicks
- widgets
- weather triggers
- an iOS companion
- live search of stock sites
- community uploads without review
- localisation beyond English *(Claude's call: build with String Catalogs so it can be added)*

## 5. Anti-goals

Any of these makes Kinora a failure even if it otherwise works:

- Telemetry, analytics, accounts, ads or a paywall.
- Network traffic the user didn't ask for. The only network uses are the gallery when opened, downloads the user starts, and update checks the user turned on.
- Shipping content we have no right to redistribute. This is why Pexels and Pixabay are out: both ban wallpaper apps from distributing their content ([Pexels help](https://help.pexels.com/hc/en-us/articles/4405588861721-Can-I-use-the-API-as-a-wallpaper-app), [Pixabay terms](https://pixabay.com/en/service/terms/)).
- Copying code from licenses incompatible with GPL-3.0-or-later. That includes Muro (PolyForm Shield) and wallpaper-player-mac (no license).
- Changing or losing the user's wallpaper settings without a way back.
- Background CPU, GPU or energy use the user can't see or control.
- A generic or templated look. The UI must look deliberate and native.

## 6. Constraints

- **License:** GPL-3.0-or-later. Every source file carries an SPDX header. Code reused from Vorssaint (GPL-3.0-or-later) keeps its copyright header.
- **Stack:** Swift 6.x, SwiftUI, AppKit where needed, AVFoundation and VideoToolbox, Metal, ExtensionKit. No Electron, Qt or web-based UI.
- **Minimum OS:** macOS 26.0. The wallpaper plug-in point and Liquid Glass both start at 26. People on 14 and 15 are knowingly left out.
- **Tested platform** *(Claude's call)*: macOS 27 on Apple silicon, the only machine available.
  - The plug-in point existing on 26 is inferred, not verified by us. Muro's users report its Lock Screen working on 26.x (Muro issue #11; a Reddit report on 26.6.2).
  - macOS 26 and Intel are best effort and community-tested. Decoding of WallpaperAgent's messages must tolerate missing or extra fields, so small differences between versions don't break it.
  - If the plug-in path fails on a given Mac, Kinora says the Lock Screen and desktop plug-in are unavailable there (see the fallback renderer in 7.1). It never crashes or fights the system.
- **Architectures** *(Claude's call)*: ship a universal binary (arm64 and x86_64). It costs little. macOS 27 is Apple silicon only, so the Intel slice serves only Intel Macs on 26. Tests run on arm64.
- **Signing and distribution:**
  - No paid Apple Developer ID and no notarization.
  - Every build is signed with one stable self-signed certificate, generated once and kept for local builds and CI, so permissions survive updates. Follow Vorssaint's `Tools/setup-signing.sh` and `Tools/ci-setup-signing.sh`.
  - Releases go to GitHub, plus a personal Homebrew tap: `brew install --cask <owner>/tap/kinora`.
  - The official `homebrew/cask` repo is not an option: Homebrew 5.0 deprecated unsigned casks and set their removal for September 2026.
  - Users approve the app once in System Settings › Privacy & Security › Open Anyway. Onboarding explains it.
- **Private interfaces.** Kinora depends on several: the wallpaper plug-in protocol, `CAContext`, and the wallpaper store's format. Each path must:
  - check at runtime that what it needs exists
  - fail without crashing or corrupting anything
  - tell the user in plain words what stopped working
  Do not assume the macOS 27.0.1 shapes are permanent.
- **Identity** (owner's decision, 2026-11-12):
  - **GitHub:** the repo will be `Sky-walkerX/kinora` and the Homebrew tap `Sky-walkerX/homebrew-tap`, installed with `brew install --cask sky-walkerx/tap/kinora`. The gallery repo will be `Sky-walkerX/kinora-gallery`.
  - **Bundle IDs:** `io.github.sky-walkerx.kinora` for the app and `io.github.sky-walkerx.kinora.wallpaper` for the plug-in. They are permanent once released, because the plug-in's ID is written into users' wallpaper settings.
  - **Copyright line in every source file:** `Copyright (C) 2026 The Kinora Contributors`, next to the `SPDX-License-Identifier: GPL-3.0-or-later` line.
  - **`CONTRIBUTORS` file:** names `Sky-walkerX` as founder and maintainer.
  - **Files adapted from Vorssaint** keep Vorssaint's copyright line and add Kinora's.
  - **No personal names or emails in the repo.**
- **Repo and CI before going public:**
  - The repo lives at `~/Coding/Dev/kinora` as local git only.
  - CI runs locally through the same one-command build and test. A GitHub Actions workflow is written but takes effect only once the repo is public, which is when Actions minutes become free.
  - Nothing is pushed to GitHub, and nothing is released, without the owner's explicit go-ahead.
- **Testing** (owner's decision):
  - On-device checks run on the owner's everyday Mac and account: Mac17,3, macOS 27.0.1, one built-in display.
  - Kinora's own backup and restore of the wallpaper store protects the owner's settings, and every test session ends by restoring them.
  - Checks that need a person, such as lock and unlock, become a short checklist for the owner at each milestone gate. Everything else is scripted.
  - External displays, macOS 26 and Intel stay marked untested until such hardware is available.

## 7. How it works

### 7.1 Pieces

- **`Kinora.app`**: the SwiftUI app.
  - Holds the library, gallery, import, settings, onboarding, menu bar extra and App Intents.
  - Owns all state and writes the wallpaper selection.
  - Not sandboxed: it must write `~/Library/Application Support/com.apple.wallpaper/Store/` and run `pluginkit`. Hardened runtime on.
- **`KinoraWallpaper.appex`**: a `com.apple.wallpaper` ExtensionKit plug-in inside `Kinora.app/Contents/Extensions/`.
  - It is the only renderer on the normal path: desktop, Lock Screen and screen saver, every display.
  - Sandboxed, which macOS requires. macOS launches and stops it.
- **`KinoraKit`**: shared code used by both.
  - The library and catalog models, configuration encoding, power policy, and coverage maths.
  - Pure decision logic lives in `*Support.swift` files with no system side effects, so tests can cover it. This follows Vorssaint's convention.
- **Fallback desktop renderer** *(Claude's call: not built in v1 unless needed)*.
  - It would draw desktop-level windows on each display, with no Lock Screen, and would require the app to keep running.
  - **v1 ships only detection and a plain message:** "The Lock Screen and desktop plug-in is unavailable on this Mac because …". It does not block the release.
  - **It gets built only if** the plug-in path is blocked in practice (Apple enforces the entitlement, or a supported macOS version rejects it), or the WebKit spike in milestone 6 fails and web wallpapers are still wanted. In that case it becomes its own milestone.
- **Data sharing between app and plug-in.** The plug-in is sandboxed and needs a way to read the library and settings, so use an app group container or a shared directory the app grants access to.
  - The builder chooses the mechanism, but it must work with self-signed builds.
  - An app group may need a team ID prefix. If it does, use a security-scoped bookmark or a location the plug-in's sandbox can read.
  - The choice's `configuration` Data, passed to the plug-in on every acquire, carries the wallpaper ID and its per-surface settings.

### 7.2 The plug-in protocol

The spike established and verified the protocol, the message objects, the entry-point requirement (`-e _NSExtensionMain`), registration (launch the app once, then `pluginkit -e use`), the settings view-model schema and the snapshot format. See the spike report; don't re-derive them. Kinora implements the same interface in production quality:

- **Acquire.** Build the surface for the given `destination` (display, size, scale) and reply with a remote `CAContext` ID.
  - Never return a surface that shows black. Show a still of the wallpaper until the first video or shader frame is ready, then cross-fade.
- **Update.** Apply `presentationMode`, `activityState`, `systemAppearance` and `destination` changes. Locking and unlocking arrive here.
- **Snapshot.** Return an IOSurface of the current frame at the destination's pixel size. WallpaperAgent uses it for exports. The spike saw the export succeed.
- **Provide settings view models.** Return Kinora's library as groups and tiles for the `desktop` and `screenSaver` content types. Use `updateSettingsViewModels` on the host proxy when the library changes.
- **Invalidate.** Tear down the surface and free the decoders.
- Implement the other calls (`isChoiceDownloaded`, `selectedChoicesDidChange`, download, shuffle, migration and debug) safely. Unsupported operations return an error, never a crash.

### 7.3 Choosing a wallpaper

Users choose in Kinora or in System Settings.

**From System Settings:** the user picks a Kinora tile, and macOS writes the store itself.

**From Kinora:**
- The app writes the choice into WallpaperAgent's store.
- Before the first write, it backs up the store, keeping one rolling backup plus the pre-Kinora original.
- Writes are atomic and validated.
- Read and write both store shapes seen in the wild: `Index.plist`, `Index_v2.plist`, and `Linked` nodes. Muro's issues show some Macs keep one shared entry and others keep one per screen.
- Study Vorssaint's `Services/Wallpaper/` for how it reads and writes this store.

**Applying without a blink** (open item):
- The spike applied choices by restarting WallpaperAgent, which blinks every display.
- System Settings applies them without a restart, so a quieter path exists. WallpaperAgent listens on `com.apple.wallpaper` and `com.apple.wallpaper.public`.
- Find it during milestone 1. Restart only as a fallback.

**Lock Screen vs desktop:** macOS shows the same choice on both and tells the plug-in which one it's drawing (`presentationMode`). A Kinora choice can therefore hold two wallpapers, one for `default` and one for `locked`, and the plug-in cross-fades between them on lock and unlock.

**Per display and per Space:** use the store's `Displays` and `Spaces` nodes, and the "Show on all Spaces" behaviour System Settings already has. Verify both on real hardware during the milestone that adds them.

**Self-repair, checked at every app launch and after each selection:**
- the plug-in is registered and enabled (re-run `pluginkit -e use` if needed)
- the store still names Kinora where the user chose Kinora
- WallpaperAgent is running the plug-in

Fix what can be fixed. Explain what can't.

**Not fighting other writers** *(Claude's call)*: System Settings, Vorssaint's wallpaper feature and other apps write the same store.
- When another writer replaces a Kinora choice, Kinora treats it as the user's new decision and does not put itself back.
- Self-repair only re-enables the plug-in and fixes entries that still name Kinora.
- The app shows "Kinora is not your current wallpaper" with a one-click "Use Kinora again".

### 7.4 What Kinora can render

- **Video:**
  - HEVC and H.264 with hardware decode.
  - Loops must be gapless. Imported videos are trimmed or cross-faded at the loop point when they don't loop cleanly.
  - Imports are converted to HEVC once, at a size and bitrate suited to the display, keeping the original until the user deletes it.
  - The spike's plain `AVPlayer` used about 2% of a core at 2560x1664, 30 fps. The goal is to beat that, for example with `AVSampleBufferDisplayLayer` or a direct VideoToolbox path, but measure before choosing.
  - Apple's own `VideoWallpaper` in WallpaperExtensionKit uses a custom sample reader, which hints the cheaper path exists.
- **Shaders:** Metal fragment shaders drawn into a `CAMetalLayer` inside the remote context.
  - Frame rate capped at 30 fps by default, user-adjustable.
  - Optional lower internal resolution.
  - Kinora's own built-in set: aurora, rain on glass, slow gradients, lava lamp, plus more as time allows. Shaders take parameters, such as colours and speed, that show as options.
- **Images and slideshows,** with cross-fades. GIFs are converted to HEVC on import.
- **Web wallpapers,** from Lively and Wallpaper Engine imports. They depend on a spike: does WebKit run inside the sandboxed plug-in?
  - If yes, the plug-in renders them.
  - If no, they run only in the fallback desktop renderer, with no Lock Screen, and the UI says so.
- **Variants:** light/dark, time-of-day schedule, Lock Screen vs desktop, and rotation through a playlist on a timer or on wake.

### 7.5 Power model

Battery use is one of Kinora's main selling points, so the rules are part of the design, not an afterthought.

**Signals from macOS:**
- `activityState` (`active` or `suspended`). Obey it; treat `suspended` as "release the decoder".
- `presentationMode` (`default`, `locked` or `idle`).
- Display sleep.

**Kinora's own signals:**
- Desktop coverage. macOS does not send `suspended` for windows covering the desktop, as the spike observed. The plug-in, or the app on its behalf, computes how much of each display's desktop is visible from the window list, which needs no permission for window bounds.
- On battery or plugged in.
- Low Power Mode.
- Thermal state.

**Behaviour per wallpaper**, with defaults the user can change *(Claude's call)*:
- **Visible:** play at the content's frame rate.
- **Desktop at least 95% covered, or a full-screen app on this display:** pause and hold the frame.
- **On battery:** cap at 30 fps.
- **Low Power Mode, or thermal state `serious` or worse:** pause.
- **Optional "Apple-style" mode:** play on the Lock Screen and for a few seconds after unlock, then settle on a still. Apple's aerials work this way and cost 0% on the desktop.

**Energy readout:**
- The app shows, per wallpaper and in the menu bar extra, the plug-in process's CPU time and energy.
- Read these from `proc_pid_rusage`; the energy field is the builder's choice.
- Show it as a plain number with a short explanation, not a coloured gauge.

**Benchmarks:**
- A documented, repeatable method using `powermetrics`, which needs sudo.
- Same video, same display, same duration; Kinora vs Muro vs Backdrop vs Wallper (trials).
- Results and raw data are published in the repo.

### 7.6 Import

- **User files:** drag in videos, images, GIFs or folders. Copy them into Kinora's library and convert video once.
- **Lively:** packages with `LivelyInfo.json`. Verify the schema from Lively's own GPL source. Video and web types only.
- **Wallpaper Engine:** folders with `project.json`, typically a Workshop folder copied from a Steam install. Video and web types only. Report scene types as "not supported yet" instead of hiding them.
- **Apple aerials:** list the aerials macOS has already downloaded and play them in place. Never copy or redistribute them.
- **Containers AVFoundation can't open** *(Claude's call)*. Many Wallpaper Engine and Lively videos are WebM or MKV, with VP9 or VP8 inside. "Native only" is read as: no bundled C media libraries such as FFmpeg.
  - Kinora gets a small Matroska/WebM reader in Swift for import.
  - It feeds VP9 frames to VideoToolbox (VP9 decode via `VTRegisterSupplementalVideoDecoderIfAvailable`) and re-encodes once to HEVC.
  - AV1 goes through VideoToolbox where the hardware supports it.
  - VP8, and anything else the system can't decode, is reported per file: "This video uses a format macOS can't decode. Convert it to MP4 first." The message links to a short how-to.
  - This work belongs to milestone 6.

### 7.7 Gallery

- **Content:** footage Kinora may legally redistribute:
  - NASA public-domain video
  - ESA and ESO video under CC BY
  - Wikimedia Commons CC0 or CC BY
  - Blender open-movie clips under CC BY
  - contributions licensed CC0 or CC BY 4.0 by their authors
- **Rules for every entry:**
  - Each entry records its source URL, license and credit, and the app shows them.
  - No Pexels or Pixabay.
- **Hosting:**
  - A separate `kinora-gallery` repo holds `catalog.json` and the review rules.
  - Media lives in that repo's GitHub releases, which are free.
  - New entries arrive by pull request and are reviewed for license and quality.
- **Fetching:** the app fetches the catalog only when the user opens the gallery, and downloads only what the user picks. The gallery can be turned off. The catalog has a schema version so old apps keep working.
- **Ultrawide** entries are welcome, since three requests came up in research.

### 7.8 UI

The UI follows the macOS 26 Human Interface Guidelines and uses Liquid Glass through standard SwiftUI.

- **Main window:**
  - sidebar sections: Library (yours, Kinora Originals, Apple), Gallery, Displays
  - a large live preview
  - for the selected wallpaper: where it's applied (desktop, Lock Screen, screen saver, which displays), its options, and its energy cost
- **Settings:**
  - General: launch at login, menu bar extra, updates
  - Playback & Battery: the power rules above
  - Displays & Spaces
  - Lock Screen
  - Gallery: on or off, download location
  - Advanced: repair, logs, restore original wallpaper
  - About: licenses and credits
- **Menu bar extra** (optional): pause or resume, next in playlist, current energy, quick switch.
- **App Intents and Shortcuts:** set a wallpaper, pause or resume, next, and battery mode.
- **Onboarding, in three short steps:**
  1. Explain the first-launch approval.
  2. Turn on the plug-in.
  3. Pick a first wallpaper from Kinora Originals, which needs no download.
- **Accessibility:** VoiceOver labels, Reduce Motion (offer to pause wallpapers), and Reduce Transparency.

### 7.9 Install, update and uninstall

- **Install:**
  - Distribute a DMG or zip from GitHub releases, and a cask in the owner's own tap.
  - First launch registers the plug-in.
  - Before the first public release, test end to end: a downloaded, quarantined, self-signed copy → Open Anyway → plug-in launches → Lock Screen plays.
- **Updates:**
  - Sparkle 2 (MIT, GPL-compatible) with an EdDSA-signed appcast hosted with the GitHub releases.
  - Automatic checks are off until the user turns them on, in onboarding or Settings. A "Check for Updates" button always works.
- **Uninstall:** "Remove Kinora" in Settings › Advanced, also documented for manual use:
  - restores the pre-Kinora wallpaper choice
  - disables and unregisters the plug-in, so the System Settings section disappears
  - removes caches and the library, after asking
  - tells the user to drag the app to the Bin

### 7.10 Build, test and CI

- **Build** with one command (`./build.sh`) that produces a signed `Kinora.app` with the embedded plug-in.
  - SwiftPM cannot produce `.appex` bundles, so bundle assembly is scripted, as in Vorssaint and the spike.
  - Xcode project or not is the builder's choice, as long as the one-command build and test work from the terminal.
- **Test** with one command (`./build.sh test` or similar), covering `KinoraKit` logic:
  - power policy, coverage maths, store reading and writing on fixture plists, catalog parsing
  - Lively and Wallpaper Engine manifest parsing on fixture files
  - configuration encoding, and the message objects' JSON round-trip against the shapes in the spike report
- **On-device checks for every rendering path**, recorded with what was observed and what was inferred:
  - CPU, GPU, energy and memory, using Activity Monitor or `powermetrics`
  - Lock Screen behaviour
  - Follow Vorssaint's `docs/AI-CONTRIBUTIONS.md` habit of evidence-based verification.
- **CI:** GitHub Actions on a macOS runner builds and tests every push. Releases are built by a tagged workflow that signs with the stable certificate kept in secrets.

### 7.11 Reuse

- **Vorssaint (GPL-3.0-or-later):**
  - the build and signing scripts
  - the `*Support.swift` testing pattern
  - store-handling knowledge from `Services/Wallpaper/`
  - the `NotchOverlaySpace` idea, only if a Lock Screen fallback is ever needed
  Keep the headers on anything copied.
- **Muro, Backdrop and Wallper:** study only. Copy no code.
- **Lively:** file formats only.

## 8. Milestones

Each milestone ends with on-device verification and recorded evidence.

1. **Foundation.** The repo with GPL headers, README skeleton, `./build.sh` build and test, signing setup and CI, plus `KinoraKit` with tests.
2. **First vertical slice.** The plug-in plays a video the user picked, on the desktop and the Lock Screen of every display:
   - pause when covered, on battery and in Low Power Mode
   - snapshot support
   - tiles in System Settings
   - selection from Kinora with backup and restore
   - self-repair
   - the energy readout
   Include the spike that finds a way to apply a selection without restarting WallpaperAgent.
3. **Library and import:** user files, HEVC conversion, Apple aerials, playlists, light/dark and time-of-day variants, and Lock Screen vs desktop.
4. **Kinora Originals:** the shader renderer and the first set of shaders.
5. **Gallery:** the `kinora-gallery` repo, catalog, download flow and attribution.
6. **Lively and Wallpaper Engine import** for video, including the WebM reader, plus the WebKit-in-plug-in spike and web wallpapers. If the spike fails, decide here whether to build the fallback renderer (7.1).
7. **Polish and release:**
   - onboarding, Settings, menu bar extra and App Intents
   - accessibility
   - uninstall
   - Sparkle
   - benchmarks
   - the quarantined-download test
   - the tap
   - the first release, when the owner says go

## 9. Risks

| Risk | Effect | Response |
|---|---|---|
| Apple enforces `com.apple.private.wallpaper.extension` on the plug-in point | Plug-in rendering, and with it the Lock Screen, stops working | Detect it, switch to the fallback desktop renderer, tell users plainly. Track macOS betas. |
| The message shapes change in a macOS update | Acquire or update fails to decode | Decode leniently; log failures in plain words; keep the spike's probe tools to re-derive shapes quickly. |
| No quiet way to apply a selection | Every apply blinks the screen | Prefer System Settings as the place to pick, and restart only on explicit apply. |
| A quarantined, self-signed plug-in may not launch after Open Anyway | Downloaded installs lose the Lock Screen | Test before the first release. If it fails, onboarding guides a `pluginkit` re-enable, or a documented `xattr` step for the tap. |
| WebKit doesn't run in the sandboxed plug-in | Web wallpapers are desktop-only | Fallback renderer, labelled. |
| The gallery is thin at launch | First impression suffers | Kinora Originals ship built in, so there's always content. |

## 10. Left to the builder

- Xcode project vs scripted build, and the folder layout.
- How app and plug-in share the library and settings, within the self-signed constraint.
- The exact video decode path, chosen by measurement.
- The energy metric used in the readout.
- The coverage check's implementation and where it runs, in the app or the plug-in.
- Shader authoring format, and how parameters map to options.
- `catalog.json` schema details, with a version field.
- Visual design details, within the HIG and Liquid Glass.
- The test framework (Swift Testing or XCTest).
