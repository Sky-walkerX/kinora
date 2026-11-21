# Evaluation: WebM video and web wallpapers

Date: 2026-11-13, updated 2026-11-20. Written in Linux cloud sessions with GitHub's macOS 26 runners for builds and probes. **Nothing here has been run on a real Mac yet.** It records what Kinora does now, what is known, and the exact spikes that must run before anything is promised.

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

CI results for the converter are in the handoff. Still to check on a real Mac: real Lively and Workshop WebM files the owner already has (none are shipped as fixtures), long and 4K files (time and memory), and VP9 decoding on Apple silicon hardware rather than the runner's virtual decoder.

## Web wallpapers: the WebKit-in-plug-in spike

The question: can the sandboxed `com.apple.wallpaper` plug-in host a `WKWebView` whose pixels reach WallpaperAgent through the remote `CAContext`, on the desktop and the Lock Screen, at an acceptable cost?

Why it is uncertain:

- `WKWebView` renders in a separate WebContent process and composites through its own remote layers. Whether those layers show when the view's layer is re-hosted in a `CAContext` that WallpaperAgent owns is unknown.
- WebKit may require a window, a run loop mode or entitlements the plug-in lacks (`com.apple.security.network.client` for remote content; local files need read access, which the library exception already gives).
- On the Lock Screen, WallpaperAgent may not grant the WebContent process the visibility it needs to draw.

The spike, to run on the owner's Mac with the existing spike plug-in in `docs/spikes/2026-11-12-lock-screen/` as the base:

1. In `acquire`, create an offscreen `NSWindow` (borderless, not ordered front) holding a `WKWebView` sized to the destination, load a local HTML file with a CSS animation and a canvas animation, and add the web view's `layer` (or the window's content view layer) to the remote context's layer tree.
2. Record: does the desktop show the page; does it animate; does the Lock Screen show it; what WallpaperAgent and the plug-in log; CPU and energy of the plug-in and of its WebContent process (`top -l` and `powermetrics`, as in the Lock Screen spike).
3. If the layer is blank, try `WKWebView.takeSnapshot` into a layer's contents at a low frame rate, as a fallback, and measure its cost.
4. Restore the owner's wallpaper at the end.

Decision rule:

- If the page animates on the desktop and Lock Screen at under about 3% of a core for a simple animation, add web wallpapers for local, imported pages only, with no network entitlement, and a power cap like the originals'.
- If it shows only on the desktop, decide with the owner whether a desktop-only, app-hosted fallback renderer (design §7.1) is worth building. It would need Kinora to keep running.
- If it doesn't show, keep refusing web wallpapers with the current message.

No web wallpaper support is promised until this spike has run.
