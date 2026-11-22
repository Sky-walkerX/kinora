# Evaluation: WebM video and web wallpapers

Date: 2026-11-13, updated 2026-11-22. Written in Linux cloud sessions with GitHub's macOS 26 runners for builds and probes. **Nothing here has been run on a real Mac yet**; the WebKit probe ran on CI. It records what Kinora does now, what is known, and the exact spikes that must run before anything is promised.

## What Kinora does today

- **WebM and MKV** (updated 2026-11-21): converted to HEVC once, at import, by Kinora's own reader and VideoToolbox; see "WebM" below. VP8, and AV1 on Macs without an AV1 decoder, are explained by name ("Its video is VP8, which macOS can't decode. Convert it to MP4 (H.264 or HEVC) first.").
- **Web wallpapers** (Lively `web`, `webaudio` and `url`; Wallpaper Engine `web`) are refused with: "Kinora doesn't show web wallpapers yet: whether they can run safely inside macOS's wallpaper system is still being tested."
- **Wallpaper Engine scenes** are refused as needing a renderer Kinora doesn't have. They stay out of scope.

## WebM

Observed on GitHub's macOS 26 runner on 2026-11-20 (`ContainerProbeTests`, with one-second ffmpeg test patterns in `Tests/Fixtures/containers/`):

1. **AVFoundation does not open WebM or Matroska.** VP9 in WebM, VP9 in MKV, VP8 in WebM and AV1 in WebM all fail with "Cannot Open": not playable, no tracks. HEVC in MP4 opens and decodes all 10 frames.
2. **Registering the supplemental VP9 decoder doesn't change that**, but afterwards `VTIsHardwareDecodeSupported(VP9)` turns true (false before). HEVC and AV1 report hardware decode on that runner. So VideoToolbox can decode VP9 frames once Kinora hands them over; only the container is missing.

Built on 2026-11-21, as planned:

- `MatroskaReader` (KinoraKit, pure Swift, no FFmpeg) walks EBML on demand: the first enabled video track, SimpleBlocks and BlockGroups, Xiph, EBML and fixed lacing, unknown-size segments and clusters (browser recordings), cut-off files up to their last whole frame, header stripping undone; encryption and real compression refused. Every size is checked against its parent and the file; headers, frames, track counts and picture sizes are capped.
- `MatroskaCodecs` builds what VideoToolbox needs: `avcC`, `hvcC` and `av1C` from CodecPrivate, and for VP9 a `vpcC` record from the first keyframe's uncompressed header (profile, bit depth, subsampling, colour), with the VP9 level from size and rate. Superframes are split to find the keyframe.
- `MatroskaConverter` (KinoraMedia) decodes with `VTDecompressionSession` (VP9 after registering the supplemental decoder), puts B-frames back in presentation order, and encodes HEVC once at the display's size through `AVAssetWriter`, then the item goes through the ordinary library path. 10- and 12-bit sources are converted to 8 bits; colour is written as BT.709.
- Fixtures (synthetic, `Tests/Fixtures/containers/README.md`): VP9 plain, live (unknown sizes), with superframes, 10-bit and with alpha; H.264 and HEVC with B-frames in MKV; VP8; AV1.

Observed on CI (2026-11-21, run 34): every VP9, H.264 and HEVC fixture converts to 10 frames and 1.0 s, each frame closer to the HEVC reference's decode than its neighbour is. The runner reports AV1 hardware decode but can't create an AV1 decoder session, so AV1 conversion is untested and refused by name there. Still to check on a real Mac: real Lively and Workshop WebM files the owner already has (none are shipped as fixtures), long and 4K files (time and memory), and VP9 decoding on Apple silicon hardware rather than the runner's virtual decoder.

## Web wallpapers: the WebKit-in-plug-in spike

The question: can the sandboxed `com.apple.wallpaper` plug-in host a `WKWebView` whose pixels reach WallpaperAgent through the remote `CAContext`, on the desktop and the Lock Screen, at an acceptable cost?

Why it is uncertain:

- `WKWebView` renders in a separate WebContent process and composites through its own remote layers. Whether those layers show when the view's layer is re-hosted in a `CAContext` that WallpaperAgent owns is unknown.
- WebKit may require a window, a run loop mode or entitlements the plug-in lacks (`com.apple.security.network.client` for remote content; local files need read access, which the library exception already gives).
- On the Lock Screen, WallpaperAgent may not grant the WebContent process the visibility it needs to draw.

The spike, to run on the owner's Mac with the existing spike plug-in in `docs/spikes/2026-11-12-lock-screen/` as the base:

1. In `acquire`, create an `NSWindow` (borderless, ordered in far off every display, with WebKit's occlusion detection off, as the CI probe below found necessary) holding a `WKWebView` sized to the destination, load a local HTML file with a CSS animation and a canvas animation, and add the web view's `layer` (or the window's content view layer) to the remote context's layer tree.
2. Record: does the desktop show the page; does it animate; does the Lock Screen show it; what WallpaperAgent and the plug-in log; CPU and energy of the plug-in and of its WebContent process (`top -l` and `powermetrics`, as in the Lock Screen spike).
3. If the layer is blank, try `WKWebView.takeSnapshot` into a layer's contents at a low frame rate, as a fallback, and measure its cost.
4. Restore the owner's wallpaper at the end.

Decision rule:

- If the page animates on the desktop and Lock Screen at under about 3% of a core for a simple animation, add web wallpapers for local, imported pages only, with a power cap like the originals'. WebKit needs `network.client` (CI probe below), so only if the owner accepts it, ideally in a second, web-only plug-in, with every non-file load blocked.
- If it shows only on the desktop, decide with the owner whether a desktop-only, app-hosted fallback renderer (design §7.1) is worth building. It would need Kinora to keep running.
- If it doesn't show, keep refusing web wallpapers with the current message.

No web wallpaper support is promised until this spike has run.

### Sandbox half, run on CI (2026-11-22)

`docs/spikes/2026-11-22-webkit-probe/` holds a probe app, `WebProbe`, signed as the plug-in is (ad hoc, hardened runtime) three ways: with **exactly** `Resources/Wallpaper/KinoraWallpaper.entitlements`; with those plus `com.apple.security.network.client`; and unsandboxed. It loads `page.html` (a CSS animation, a canvas drawn every `requestAnimationFrame`, a 100 ms timer) from `~/Library/Application Support/Kinora/WebProbe/`, the folder the plug-in may read, and measures each way of hosting it. The "WebKit probe" workflow runs it; `run.sh` runs it on a Mac too.

Observed on GitHub's macOS 26.7.2 runner (virtual Mac, one virtual display), WebKit probe runs 1 and 2 (2026-11-22, on 5265937 and 0226ca1). The network and unsandboxed variants agreed in every scenario, and run 2 repeated run 1:

| Scenario | Page loads | rAF / s | CSS ms / s | Timer / s | `visibilityState` |
|---|---|---|---|---|---|
| Plug-in's exact entitlements, any window | **no**: WebContent ends at once (`reason=Crash`) | — | — | — | — |
| + `network.client`, or no sandbox: visible window | yes | 47–52 | 1086–1126 | 7.8–8.8 | visible |
| hidden window (never shown), as in a plug-in | yes | 0 | 0 | 2.5–2.9 | hidden |
| hidden, WebKit's occlusion switch off | yes | 0 | 0 | 2.3–2.6 | hidden |
| hidden, hidden-page timer and suppression switches off | yes | 0 | 0 | 7.1–7.7 | hidden |
| ordered in far off every display | yes | 0 | 0 | 2.3–2.6 | hidden |
| **ordered in far off every display, occlusion switch off** | yes | **51–53** | **1002–1003** | 8.1–8.4 | **visible** |

Re-hosting (the web view's layer tree moved into a remote `CAContext`, which a visible window of the probe hosts with a `CALayerHost` and captures, standing in for WallpaperAgent): WebKit draws with layers in the probe's own process (`WKCompositingLayer`s, no `CALayerHost` of its own), so the tree can be moved. With the page hidden, the hosted pixels turned flat white after the move and stayed so. **With the off-screen window and the occlusion switch off, the hosted pixels were the page's (varied, mean luma 62–68 of 255, not the magenta placeholder) and kept changing (mean difference 25–41 between captures a second apart), at 60 rAF frames a second.**

Other details: WebKit's switch for CSS animations in hidden pages (`_setHiddenPageCSSAnimationSuspensionEnabled:`) doesn't exist on this macOS; the others do. The sandbox logged only minor denials for WebKit's processes in every variant (`analyticsd`, `syscfg` IOKit properties, `opendirectoryd.libinfo`), none naming the cause of the plug-in variant's failure, and no WebContent crash report was written.

What this establishes, and doesn't:

- **The plug-in as it is can't run WebKit.** It needs `com.apple.security.network.client`, which Kinora's plug-in deliberately lacks. The entitlement allows connections; it doesn't make any. Web wallpapers would still have to block every non-file load (a `WKContentRuleList` and a non-persistent data store), and the entitlement could live in a **second, web-only wallpaper plug-in** so the one that plays videos and originals keeps the smallest sandbox. That is the owner's call.
- **A page keeps moving unseen only in a window that is ordered in and off screen, with a private WebKit switch** (`_setWindowOcclusionDetectionEnabled:`, looked up at runtime). Ordering the window out is then a natural pause: the page goes hidden and stops drawing, which fits the power rules.
- **Its pixels survive being re-hosted through a remote context** in-process, by the mechanism WallpaperAgent uses to show the plug-in. Not shown: that a sandboxed ExtensionKit plug-in may create and order in a window at all, that WallpaperAgent shows the result on the desktop and Lock Screen, and what the WebContent and GPU processes cost. Those need the owner's Mac, step 1 to 3 above, built on what this probe found.
- Until then the refusal message stays.

