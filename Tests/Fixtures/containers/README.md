One-second, 96×64 test patterns (ffmpeg's `testsrc2`), made for `ContainerProbeTests` to record which
containers and codecs AVFoundation opens on the Mac running the tests. Regenerate with, for example:

```sh
ffmpeg -f lavfi -i testsrc2=size=96x64:rate=10 -t 1 -c:v libvpx-vp9 -b:v 50k -pix_fmt yuv420p vp9.webm
```

`vp9.webm`, `vp9.mkv`, `vp8.webm` (libvpx), `av1.webm` (libaom) and `hevc.mp4` (libx265, tagged `hvc1`).
