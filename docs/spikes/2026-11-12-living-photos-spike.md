# Spike: Living Photos

Date: 2026-11-12. Machine: Mac17,3, macOS 27.0.1.

Question: can Kinora turn a still photo into a living wallpaper that works on the desktop and the Lock Screen at low power? macOS has no depth or spatial wallpaper type (see `docs/research/2026-11-12-competitor-gaps.md`).

**Result: yes.** It's feasible and fast. The quality is good for photos with a clear subject; filling the gap behind the subject is the weak spot.

## Approach (`2026-11-12-living-photos/livingphoto.swift`, throwaway)

1. **Scale.** Scale the photo to cover the display plus 8% overscan, so motion never shows an edge.
2. **Lift the subject.** Vision's `VNGenerateForegroundInstanceMaskRequest` gives the mask. Pull its edge in by 2 px and soften it.
3. **Fill the hole.** Fill the subject's place in the background by normalized convolution: `blur(photo × keep) / blur(keep)` at three scales. Nearby pixels win, and the widest blur only fills what's left, so no ghost of the subject remains.
4. **Frame.** Centre the crop on the subject, keeping its top in view with 8% headroom.
5. **Animate.** Move the two layers on a figure-eight: the subject 1.1% of the width, the background 0.4× that, with a slight zoom. Both are sines of the loop phase, so the end meets the start exactly.
6. **Render.** Render a 12-second loop with Core Image on the GPU and encode it as HEVC. It then plays through Kinora's existing video path: desktop, Lock Screen and battery rules, with no new renderer.

## Measurements

Test photo: NASA's public-domain AS11-40-5903 (Buzz Aldrin on the Moon), 3912×3936. It isn't stored in the repo.

| Step | Result |
|---|---|
| Subject mask | 0.15–0.26 s, one instance, clean silhouette |
| Render of a 12 s, 30 fps loop at 2940×1912 | 7–11 s |
| Output | 10–11 MB of HEVC |
| Playback | same as any Kinora video, about 1.5% of one core, measured for a similar video |

## Round 2: the three fixes

Done the same day, after the owner asked for them.

- **Less motion.** The subject now moves 0.75% of the width, and the background 0.45× that. The subject's offset against the background dropped by about 40%, to about 12 px on a 2940 px display.
- **Colour sampling.** It now uses a hard-edged gap, grown 1% and thresholded, that excludes every subject pixel. Version 1's softened mask let the white suit leak in as a pale blob.
- **Sideways fill.** The fill blurs sideways only (`CIMotionBlur` at angle 0, three radii), so the gap takes colour from the background at the same height instead of the sky above; a light blur then softens row streaks.
- **Texture transfer.** Fine detail (photo minus a 2.5 px blur) is copied from beside the subject as one coherent block: the left half from the left, the right half from the right, with a feathered seam. The photo's grain comes with it, so grain matches. This takes 0.2 s on the CPU at 3176×3195.

Result: no pale blob and no dark core in the gap, clean edges with no halo, and the revealed band reads as textured ground. The background layer alone shows faint horizontal streaks, but only the thin band beside the moving subject is ever visible. Rendering now takes 5–6 s.

## What works and what doesn't

- **Works:** the depth effect reads clearly; framing keeps the subject's head in; the loop is seamless; no new playback path.
- **Weak:** the gap behind the subject fills with smooth colour where the real ground is textured, which shows during motion if you look closely.
  - Options: less subject motion, matching grain over the fill, or texture-synthesis (patch-based) inpainting.
  - Apps can't use the generative fill iPhone uses for spatial scenes.
- **Untested:**
  - photos with several subjects, or none (landscapes would need a depth model, such as Depth Anything V2 Small in Core ML, Apache-2.0)
  - portrait photos with faces
  - a real-time Metal version, which could cost less than video decoding for slow motion
