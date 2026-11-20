# Benchmarks

Kinora's battery claims must hold up in reproducible measurements. This page says how to measure, and records what has been measured, separating real Macs from CI's virtual ones.

## Method

1. Same Mac, same display, same power source, nothing else running; let the Mac settle for two minutes.
2. Pick the wallpaper, close every window so the desktop is clear (or keep a fixed window layout and say so).
3. `Tools/measure-plugin.sh 120 <label>` for CPU and memory every 2 s; with `sudo`, also energy from `powermetrics`.
4. Repeat for "rests while you work" (the default) and "always moving", and for each kind: video, Living Photo, each original.
5. For other apps (Muro, Backdrop, Wallper trials), measure their wallpaper process the same way.
6. Commit the CSVs from `measurements/` with the Mac model, macOS version, display and wallpaper.

## Measured on a real Mac

| Date | Mac | What | Result |
|---|---|---|---|
| 2026-11-12 | Mac17,3, macOS 27.0.1, 2940×1912 | Lock Screen spike, 2560×1664 HEVC 30 fps, `AVPlayer` | 2.09% of one core average (1.4–3.6), 13 MB |
| 2026-11-12 | same | Apple's aerial, settled on the desktop | 0.0%, 15 MB |
| 2026-11-12 | same | Living Photo spike, 12 s at 30 fps, 2940×1912 | render 5–6 s, 10–11 MB of HEVC |

Living Photo playback, originals and the current plug-in have **not** been measured on a real Mac yet.

## Measured on GitHub's macOS 26 runner (virtual Mac, paravirtual GPU)

These come from CI on 2026-11-13. The GPU and encoder are virtual and shared, so they show the code works at full size and give an order of magnitude; they are not a real Mac's cost and must not be quoted as one. Two runners an hour apart differed by up to almost three times, so ranges are given.

| What | Result |
|---|---|
| Living Photo, 4032×3024 photo → 2940×1912, 12 s at 30 fps, release build | subject found and lifted; prepare 2.8–4.5 s, render and encode 14.7–21.1 s, 17.8–25.8 s in all; HEVC, 10.6 MB; peak memory 469–598 MB |
| Living Photo, 480×300, 2 s at 15 fps, debug build | prepare 2.1 s, encode 2.6 s, 0.3 MB |
| Live Sky at 1470×956 (half of 2940×1912), 20 fps | 1.6–4.8 ms GPU per frame (3–10% of the GPU's time) |
| Aurora at 1470×956 and 30 fps, then at 1323×860 and 24 fps | 4.1 ms, then 11.6 ms per frame on a busier runner (12–28%); the costliest original |
| Tide at 735×478, 15 fps | 1.3–1.8 ms per frame (2–3%) |
| Lava Lamp at 1470×956, 24 fps | 0.9–1.3 ms per frame (2–3%) |

With the default "rests while you work", originals draw only on the Lock Screen, for a few seconds after unlock and while the desktop is clear, so their cost while you work is zero. Aurora is the one to measure first on a real Mac; if it costs more than about 2% of the GPU, lower its resolution or simplify its curtains.

## Living Photos on real photos (CI, 2026-11-20)

The "Living Photo evaluation" workflow makes a 12-second, 30 fps loop at 2940×1912 from each of ten public-domain NASA photos (`Tests/Fixtures/living-photos.tsv`) and uploads the frames, both layers and a close-up of the filled gap. Virtual Mac, release build; the first round, before the fixes below.

| Photo | What it tests | Subject found | Generation (wall) | HEVC | Seam / largest step (luma) |
|---|---|---|---|---|---|
| as11-40-5903 | one person, plain ground | 1, 10% | 15.8 s | 11.3 MB | 1.46 / 0.75 |
| jsc2025e078605_alt | studio portrait, tall photo | 1, 62% | 14.7 s | 12.3 MB | 1.47 / 0.99 |
| iss036e018174 | floating hair | 1, 19% | 15.6 s | 12.7 MB | 1.85 / 1.24 |
| S69-31740 | three people | 1 mask, 63% | 14.6 s | 12.6 MB | 1.68 / 1.20 |
| KSC00pp0964 | two people and an owl | 1, 48% | 17.5 s | 11.4 MB | 1.57 / 0.99 |
| NHQ201805030036 | fur | 1, 49% | 15.4 s | 13.8 MB | 1.95 / 1.49 |
| KSC-2009-1908 | small bird in branches | 1, 1% | 14.7 s | 12.3 MB | 1.87 / 1.10 |
| PIA23374 | landscape, no subject, 1400×788 | none; drifts as one layer | 13.0 s | 12.0 MB | 2.45 / 2.31 |
| KSC-20200715-PH-JBS01_0019 | sunset, thin grass | the sun, 0.2% | 13.8 s | 13.8 MB | 1.48 / 0.78 |
| PIA03830 | 1240×3043 strip | 1, 12% | 16.4 s | 5.4 MB | 0.80 / 0.48 |

What the frames show:

- **Masks are good** on people, a group (one mask for all three), fur, floating hair and a small bird. Framing keeps heads in, except where a head touches the photo's top edge (KSC00pp0964), which overscan can't recover.
- **Fixed after this round:** the strip needed a 3175×7795 canvas and about 4 GB; photos far taller or wider than the display are now cut around the subject first. The sun (0.2% of the photo) was lifted and swayed against the sea with the wrong depth; subjects under 0.5% now stay in the background.
- **Weak spots that remain:** fine hair strands Vision leaves out of the mask stay in the background and won't move with the head; a person partly hidden behind another can be split between the layers (KSC00pp0964), which may show as a tear of up to the subject's relative shift (about 12 px at 2940 wide); the fill inside large gaps is smooth or streaky, but only a thin band beside the subject is ever revealed.
- **Loop seam:** the decoded last frame differs from the first 1.2–2× as much as the largest ordinary frame-to-frame step. The motion itself closes exactly (tested), so this comes from encoding, probably the first keyframe's quality. Small (under 1% of the luma range on average), but it is the kind of flicker users notice at loop points; check it on a real display, and if it shows, try encoder pre-roll or constant-quality encoding.

## Living Photos: video or real-time?

Living Photos are rendered once into HEVC and play through the same hardware decoder as any video. A real-time renderer in the plug-in would draw two textured layers every frame instead. It might cost less than decoding for such slow motion, but it would hold both full-resolution layers in the plug-in's memory (about 40 MB each at 3176×3195) and would need its own snapshot and power handling. No measurement yet shows the video path costing too much, so Kinora keeps it. Compare the two on a real Mac with `Tools/measure-plugin.sh` before changing course.

What CI shows so far (virtual Mac, so only the shape of the comparison): decoding a whole 12-second loop took 0.37–0.52 s of CPU, about 3–4% of one core while playing, and compositing the same two layers live with Core Image took 22–44 ms a frame at 2940×1912, more than a 30 fps frame's whole budget. A dedicated Metal renderer would be cheaper than Core Image, but nothing measured so far argues for leaving the video path.
