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

These come from CI on 2026-11-13. The GPU and encoder are virtual, so they show the code works at full size and give an order of magnitude; they are not a real Mac's cost and must not be quoted as one.

| What | Result |
|---|---|
| Living Photo, 4032×3024 photo → 2940×1912, 12 s at 30 fps, release build | subject found and lifted; prepare 2.8 s, render and encode 14.7 s, 17.8 s in all; HEVC, 10.6 MB; peak memory 469 MB |
| Living Photo, 480×300, 2 s at 15 fps, debug build | prepare 2.1 s, encode 2.6 s, 0.3 MB |
| Live Sky at 1470×956 (half of 2940×1912), 20 fps | 1.6–4.0 ms GPU per frame (3–8% of the GPU's time) |
| Aurora at 1470×956, measured at 30 fps | 4.1 ms per frame (12% at 30 fps); since lowered to 24 fps at 45% resolution |
| Tide at 735×478, 15 fps | 1.3–1.4 ms per frame (2%) |
| Lava Lamp at 1470×956, 24 fps | 0.9 ms per frame (2%) |

## Living Photos: video or real-time?

Living Photos are rendered once into HEVC and play through the same hardware decoder as any video. A real-time renderer in the plug-in would draw two textured layers every frame instead. It might cost less than decoding for such slow motion, but it would hold both full-resolution layers in the plug-in's memory (about 40 MB each at 3176×3195) and would need its own snapshot and power handling. No measurement yet shows the video path costing too much, so Kinora keeps it. Compare the two on a real Mac with `Tools/measure-plugin.sh` before changing course.
