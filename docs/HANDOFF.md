# Continue Kinora

Updated: 2026-11-20, after a scheduled cloud session on branch `claude/gifted-darwin-cyae1h`. Early development; no release yet.

## Where the work is

**`main` is behind.** It stops at the 2026-11-13 handoff (4cdcf0c). Everything since, milestones 3 to 7 and this session's fixes, is on `claude/gifted-darwin-cyae1h`, which contains the earlier session's branch `claude/gifted-darwin-0w9cpx` unchanged plus the commits below. Nothing has been merged or released. A scheduled run that starts from `main` must check out this branch first, or it will redo finished work. Merging it into `main` (after the owner's review) avoids that.

## Audit at the start of this session (2026-11-20)

The stored task described `main`'s state. The previous session's branch already held most of milestones 3 to 7, built and tested on CI but never run on a Mac, so this session audited that code rather than rebuilding it. CI on the inherited branch was green (macOS 26 runner).

| Milestone | State found | Gaps found and fixed this session | Still open |
|---|---|---|---|
| 3 Library rules | Playlists, Lock Screen and Dark Mode variants, time-of-day editor, rotation, safe removal, Apple aerials, folders, pictures, GIFs | Per-unlock rotation counted one unlock per **display** (two displays skipped every other item; a two-item rotation never changed) and restarted on every plug-in restart. The app's "current" marks showed the rules' main wallpaper, not what rotation/schedule/Dark Mode/fallback actually drew. No hint that rotation or schedule overrides Dark Mode. No way into variants for a wallpaper picked in System Settings. Removing the only library item was refused even though an original could take over. | Per-display and per-Space choices. On-device checks. |
| Living Photos | Integrated: preview, three motion strengths, progress, cancel, cleanup, original untouched; tested only on one synthetic image | Evaluated on ten real public-domain photos on CI (see Validation). | Quality and power on a real Mac; re-render at another display size (the source photo isn't kept). |
| 4 Originals | Live Sky, Aurora, Tide, Lava Lamp; previews, snapshots, power rules, System Settings group | Read through the plug-in path; no bugs found. | That `CAMetalLayer` content reaches WallpaperAgent through the remote context; real GPU cost. |
| 5 Format and gallery | FORMAT.md v1, validation, installer, gallery client, staged `gallery/` repo | A security review found the installer measured zips with `zipinfo` (which reads its argument as a pattern) and extracted them whole with `ditto` before checking anything; manifest reads unbounded and through links; gallery previews via `AsyncImage` ignoring the gallery's network rules; Cancel misreported; a local package could silently replace a gallery item. All fixed (see below). | First reviewed footage; publishing `kinora-gallery` needs the owner's approval. |
| 6 Lively / Wallpaper Engine | Video, GIF, picture import; clear refusals; WebM/web evaluation doc | The same zip and path fixes apply to Lively/WE zips. Added a CI probe of which containers macOS opens. | WebKit-in-plug-in spike (needs a Mac). |
| 7 Polish | Menu bar, onboarding, Shortcuts intents and `kinora://` links, settings, update check, diagnostics, uninstall, release scripts, INSTALL/BENCHMARKS | — | Shortcuts actions don't appear (no `Metadata.appintents`); uninstall restores the original store only when Kinora is the wallpaper on every display; on-device checks. |

## What this session changed

1. **Unlocks and what is shown** (`SurfaceResolution.swift`). `UnlockCounter` counts once per lock however many surfaces report it, belongs to one rotation, and is kept in the plug-in's sandboxed preferences. `SurfaceResolution` is now the single place that decides what a surface draws, including the fallbacks for removed items; the plug-in draws with it and the app's grid, inspector, originals page and menu bar describe the screen with it, refreshing at schedule and rotation boundaries. Unlock rotations show "Changes each time you unlock", since only the plug-in can count unlocks. The inspector shows the Lock Screen's own wallpaper, explains when Dark Mode is overridden, and offers "Manage in Kinora" for a wallpaper picked in System Settings.
2. **Untrusted archives** (`ZipArchive.swift`, `PackageSource.swift`, in KinoraMedia so they are unit-tested). Kinora reads zips itself: the archive is copied into the work folder under a byte cap, its directory is checked first (no links or special files, encryption, zip64, absolute paths, `..`, or nesting past the format's depth; at most 64 entries for packages), and only the manifest and the one media file it names are inflated, under names Kinora picks, capped at the declared size and the format's limits, and CRC-checked. Folders: manifest and media must be plain files inside the package after resolving links, read with bounded reads. Videos open with reference movies forbidden; pictures must really be JPEG/PNG/HEIC. `zipinfo` and `ditto` are no longer used.
3. **Gallery and updates.** Previews load through the gallery session's rules (GitHub only, no cookies or cache, 10 MB, decoded small); the gallery text says previews load while browsing. Cancel during download no longer shows a network error; once the download finishes, Cancel becomes "Installing…". Items record their origin (`file` or `gallery:<sha256>`), so a file never replaces a gallery item or the reverse, and the gallery checks version as well as id and license. Update checks follow GitHub API redirects. Links with user names are refused in manifests and the catalog; catalog text with control characters is skipped.
4. **Validation tools.** `.github/workflows/living-photo-eval.yml` makes Living Photos from ten NASA photos listed with SHA-256 in `Tests/Fixtures/living-photos.tsv` and uploads frames and measurements as an artifact. `ContainerProbeTests` records which containers and codecs macOS opens, from tiny synthetic clips in `Tests/Fixtures/containers/`.

## Validation

**Observed on GitHub's `macos-26` runner** (virtual Apple-silicon Mac, Swift 6.3.3). Not a real Mac: no WallpaperAgent, no Lock Screen, paravirtual GPU and encoder.

- `./build.sh test` and `./build.sh` (universal release bundle): see the latest CI run on this branch. RESULT_PLACEHOLDER
- Living Photo evaluation on ten real photos: EVAL_PLACEHOLDER
- Container probe: PROBE_PLACEHOLDER

**Not observed; assumptions until checked on a Mac:** everything on screen (app UI, plug-in drawing videos, stills, aerials, originals and Living Photos on the desktop and Lock Screen, cross-fades, System Settings' tiles); that the unlock counter sees one unlock per lock on a real multi-display Mac; that `CAMetalLayer` content reaches WallpaperAgent; sandbox access to the aerial folders; real CPU, GPU, energy and memory for every path; login item, update check against a real release, uninstall, quarantined installs.

## Owner checklists

Run on the Mac, then **restore your original wallpaper** (Settings › Advanced › Restore Original Wallpaper) at the end.

Build: `git checkout claude/gifted-darwin-cyae1h && ./build.sh test && ./build.sh install`, open `~/Applications/Kinora.app`.

**Library rules**
- [ ] Make a playlist of 3 items, play it every 15 minutes with shuffle; Next changes the desktop without a blink, and the grid's checkmark moves with it.
- [ ] Play a playlist "Each Time You Unlock": lock and unlock three times; the desktop steps once per unlock (with an external display too, if you have one). Quit and relaunch Kinora, log out and in: it continues rather than starting over.
- [ ] Set a Lock Screen wallpaper different from the desktop; lock and unlock. The inspector's Status lists it.
- [ ] Set Dark Mode while a rotation runs: the inspector says the rotation decides. Stop the rotation; switching appearance changes the desktop.
- [ ] Time of Day: Day and Night, then edit a time to 2 minutes from now; the desktop and the grid's checkmark change then.
- [ ] Pick a Kinora tile in System Settings, then open Kinora: "Manage in Kinora" appears, and after it the variants do.
- [ ] Remove an item used as the Lock Screen and in a playlist: the dialog lists both; afterwards both use another item. Remove every library item while Kinora shows one: an original takes over.
- [ ] Apple Aerials: download one in System Settings, add it, use it. Remove it from Kinora: the aerial stays in System Settings.

**Living Photos** (your own photos: a portrait, a group, a landscape, a pet)
- [ ] Preview appears in a second or two; motion strengths differ; the subject message is right.
- [ ] Make one; progress moves; Stop cancels and leaves nothing in `~/Library/Application Support/Kinora/Work`.
- [ ] On the desktop and Lock Screen: no ghost of the subject in the gap, no visible loop point, no edges at full motion.
- [ ] `Tools/measure-plugin.sh 120 living-photo` (desktop clear, "Always moving"); compare with an ordinary video of the same size.

**Originals**
- [ ] Each shows and moves on the desktop and Lock Screen; System Settings › Wallpaper has a "Kinora Originals" group.
- [ ] Live Sky matches the time of day; Pause All, Reduce Motion and Low Power Mode hold the frame; "Rests while you work" settles after 5 s.
- [ ] `Tools/measure-plugin.sh 120 aurora` (and `sudo` once for energy).

**Packages, gallery, imports**
- [ ] Zip `examples/aurora-rose`, rename to `.kinorawallpaper`, double-click: installs as a tinted Aurora. Zip it inside a folder too: same result.
- [ ] Gallery › Browse: says the gallery isn't open yet (the repository doesn't exist).
- [ ] A Lively video wallpaper folder and zip, and a Wallpaper Engine video folder, import; a WE scene and a Lively web wallpaper explain why not.

**App, sleep and displays**
- [ ] Onboarding (`defaults delete io.github.sky-walkerx.kinora onboarded`), menu bar, `open kinora://pause|resume|next`, Open at Login, Save Diagnostics (no names in it).
- [ ] Sleep and wake with a video, an original and a Living Photo: no black frames.
- [ ] Remove Kinora (keep the library): original wallpaper back, no Kinora section in System Settings after relaunching it. Reinstall with `./build.sh install`.

**Before any release** (not authorized): `Tools/package-release.sh`, move the zip through a download so it is quarantined, Open Anyway, check the plug-in launches and the Lock Screen plays.

## Remaining work, in order

1. **Merge this branch** into `main` once the owner has looked at it, so scheduled runs start from it.
2. **On-device verification** with the checklists above; fix what fails.
3. Apply a selection without restarting WallpaperAgent (open since the spike; initial activation still restarts it once).
4. Per-display and per-Space choices (design §7.3). Uninstall should then also clear Kinora from displays, Spaces and the screen saver where it is still named, not only restore the original when Kinora is everywhere.
5. WebKit-in-plug-in spike (`docs/spikes/2026-11-13-webm-and-web-wallpapers.md`); decide on web wallpapers. WebM: see the probe result above before building a Matroska reader.
6. Living Photos: keep a downscaled source to re-render for a new display; lower generation's peak memory; compare with a real-time renderer only if real-Mac playback measurements justify it.
7. Gallery: choose and review the first footage; publish `Sky-walkerX/kinora-gallery` **only with the owner's approval**.
8. Shortcuts actions: produce `Metadata.appintents` (Xcode project for the app target, or `appintentsmetadataprocessor` with const-values output in `build.sh`). `kinora://` links work meanwhile.
9. Sparkle 2 needs an EdDSA key, and Developer ID/notarization needs a paid account: decide with the owner ([options](INSTALL.md)). Nothing bought, no signing material uploaded.
10. Localisation (String Catalogs), Reduce Transparency audit, VoiceOver pass.

## Development and verification

```sh
./build.sh test       # KinoraKit and KinoraMedia tests
./build.sh dev        # local debug app bundle
./build.sh            # universal release app bundle
Tools/package-release.sh   # release candidate in dist/, not published
```

Builds need macOS and Swift 6.2+. A Linux cloud session has no Swift toolchain: push to a `claude/**` branch and read GitHub's macOS CI. The "Living Photo evaluation" workflow runs on pushes that touch Living Photo code, or by hand; its artifact holds the frames. CI is never evidence of on-screen, Lock Screen, power or multi-display behaviour.

Keep native Swift/SwiftUI, GPL-3.0-or-later, no accounts, telemetry, paywalls or unsolicited networking. Private macOS interfaces need runtime checks and safe failures. The owner authorized pushing development progress to this repository; that does not authorize a release, a gallery or tap repository, purchases, or uploading signing keys.

## Copyable continuation prompt

```text
Continue work on Sky-walkerX/kinora. Check out claude/gifted-darwin-cyae1h
(or main, if it has been merged) and read README.md and docs/HANDOFF.md:
it lists what is built, what CI observed, what is still an assumption, and
the owner's on-device checklists. Start from any checklist results the
owner reports, fix what fails, then continue "Remaining work" in order.
Keep GPL-3.0-or-later, native Swift, local processing, no telemetry and no
unsolicited network access. Add tests for new logic; run ./build.sh test
and ./build.sh on macOS (GitHub's macOS CI from Linux). Record observed
results separately from assumptions. Do not publish releases, create the
gallery or tap repositories, purchase anything or upload signing material
without the owner's explicit approval.
```
