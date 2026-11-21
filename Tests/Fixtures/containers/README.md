One-second, 96×64 test patterns (ffmpeg's `testsrc2`, 10 frames at 10 fps), made for `ContainerProbeTests`,
`MatroskaReaderTests` and `MatroskaConverterTests`. They are synthetic, so they carry no third-party content.
Regenerate with, for example:

```sh
SRC="-f lavfi -i testsrc2=size=96x64:rate=10 -t 1 -an -map_metadata -1 -fflags +bitexact -flags:v +bitexact"
ffmpeg $SRC -c:v libvpx-vp9 -b:v 50k -pix_fmt yuv420p vp9.webm
```

| File | Made with | What it covers |
|---|---|---|
| `hevc.mp4` | libx265, tagged `hvc1` | Kinora's own format; the reference picture for conversions |
| `vp9.webm`, `vp9.mkv` | libvpx-vp9 | plain VP9 in WebM and Matroska |
| `vp9-live.webm` | libvpx-vp9 with `-live 1`, then the cluster's size bytes set to "unknown" (`7F FF`) | unknown-size segment and cluster, as browser recordings write |
| `vp9-altref.webm` | libvpx-vp9, two-pass, `-auto-alt-ref 1 -lag-in-frames 16` | superframes holding a hidden alt-ref frame |
| `vp9-10bit.webm` | libvpx-vp9, `-pix_fmt yuv420p10le -profile:v 2` | VP9 profile 2, 10 bits |
| `vp9-alpha.webm` | libvpx-vp9, `-pix_fmt yuva420p` | BlockGroups with BlockAdditions (the alpha plane, ignored) |
| `vp8.webm` | libvpx | VP8, which macOS can't decode |
| `av1.webm` | libaom-av1 | AV1, decoded only where the Mac has an AV1 decoder |
| `h264.mkv` | libx264, `-bf 2 -g 10` | H.264 with B-frames, stored out of presentation order |
| `hevc.mkv` | libx265, `bframes=2:keyint=10` | HEVC with B-frames in Matroska |
