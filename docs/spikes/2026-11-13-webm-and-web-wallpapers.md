# Evaluation: WebM video and web wallpapers

Date: 2026-11-13, updated 2026-11-20. Written in Linux cloud sessions with GitHub's macOS 26 runners for builds and probes. **Nothing here has been run on a real Mac yet.** It records what Kinora does now, what is known, and the exact spikes that must run before anything is promised.

## What Kinora does today

- **WebM and MKV** files, imported directly or named by a Lively or Wallpaper Engine manifest, are refused with: "Its video is WebM or MKV, which macOS can't open directly … convert it to MP4 (H.264 or HEVC) first." Detection is by extension, and AVFoundation's own `isPlayable` check catches the rest.
- **Web wallpapers** (Lively `web`, `webaudio` and `url`; Wallpaper Engine `web`) are refused with: "Kinora doesn't show web wallpapers yet: whether they can run safely inside macOS's wallpaper system is still being tested."
- **Wallpaper Engine scenes** are refused as needing a renderer Kinora doesn't have. They stay out of scope.

## WebM

Known:

- AVFoundation plays MP4 and QuickTime containers. Matroska and WebM are not among the containers `AVURLAsset` documents, and Kinora's design assumes they don't open. Safari plays WebM through WebKit's own parser, which apps can't use for files.
- macOS has a VP9 decoder in VideoToolbox, enabled per process with `VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)`. AV1 decoding exists in hardware on M3 and later.
- VP8 has no system decoder.

Observed on GitHub's macOS 26 runner on 2026-11-20 (`ContainerProbeTests`, with one-second ffmpeg test patterns in `Tests/Fixtures/containers/`):

1. **AVFoundation does not open WebM or Matroska.** VP9 in WebM, VP9 in MKV, VP8 in WebM and AV1 in WebM all fail with "Cannot Open": not playable, no tracks. HEVC in MP4 opens and decodes all 10 frames.
2. **Registering the supplemental VP9 decoder doesn't change that**, but afterwards `VTIsHardwareDecodeSupported(VP9)` turns true (false before). HEVC and AV1 report hardware decode on that runner. So VideoToolbox can decode VP9 frames once Kinora hands them over; only the container is missing.

Still to check on a real Mac: the same probe on macOS 27 and Apple silicon hardware (the runner's GPU and decoders are virtual), and that a `VTDecompressionSession` actually decodes VP9 frames from a real WebM.

Plan, since (1) is false and (2) looks workable, as the design's milestone 6 describes:

- A small Matroska/EBML reader in Swift (no FFmpeg): walk `Segment` → `Tracks` for the codec ID (`V_VP9`, `V_AV1`, `V_VP8`) and size, then `Cluster` → `SimpleBlock`/`BlockGroup` for frames and timestamps. Lacing and audio are skipped; wallpapers are silent.
- Wrap each frame in a `CMSampleBuffer` with a VP9 format description (codec private data from `CodecPrivate` or the first frame's header), decode with `VTDecompressionSession`, and feed the pixel buffers to the existing HEVC writer, once, at import.
- VP8 and anything that fails to decode keeps today's message.
- Validate on real Lively and Workshop WebM files the owner already has; ship no third-party media as fixtures. Synthetic fixtures can be made with `ffmpeg` on the owner's Mac and kept out of the repository if their encoder's licensing is in doubt.

Estimated size: a few hundred lines for the reader, plus tests on hand-built EBML and the probe's fixtures. Conversion is a one-time import cost, so playback is unaffected.

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
