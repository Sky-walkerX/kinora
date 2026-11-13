# Kinora

Live wallpapers for your Mac, on the desktop and on the Lock Screen. Free and open source.

> **Status:** early development. There is no release yet. Living Photos, Kinora Originals, the wallpaper format, the gallery client and the Lively and Wallpaper Engine imports are new: they build and pass their tests on macOS CI, but haven't yet been checked on screen on a real Mac.

For current implementation status, what has and hasn't been verified on a real Mac, and a copyable continuation prompt, see [the development handoff](docs/HANDOFF.md).

## What it does

- Plays video and animated wallpapers on the desktop and the Lock Screen, through macOS's own wallpaper system, next to Apple's in System Settings › Wallpaper.
- Keeps playing after you quit the app, because macOS itself runs Kinora's renderer.
- Rests while you work by default: moves on the Lock Screen, after unlock and when the desktop is clear, then holds a still. Pauses on battery rules, in Low Power Mode, when hot, with Reduce Motion, and shows what it costs.
- **Living Photos:** turns a still photo into a gently moving wallpaper by lifting its subject off the background, all on your Mac.
- **Kinora Originals:** generative wallpapers drawn live with Metal, including a sky that follows the real sun where you are, with no download.
- Your own videos, pictures and GIFs, converted once to a size your display needs, with the disk space saved shown. Apple's downloaded aerials, played in place.
- Playlists, a time-of-day schedule, and separate Lock Screen and Dark Mode wallpapers.
- An [open wallpaper format](docs/FORMAT.md) anyone can publish in, without Steam or a purchase, and a gallery of wallpapers that are free to share (not yet published).
- Imports video wallpapers from Lively and Wallpaper Engine folders you already have, and says plainly what it can't import.
- No account, no paywall, no telemetry. It only goes online when you browse the gallery or check for updates.

## How it works

Kinora ships a wallpaper plug-in for macOS's own wallpaper system, the same mechanism Apple's aerials use. WallpaperAgent loads the plug-in and draws what it renders under the clock on the Lock Screen and behind your windows on the desktop. The Kinora app manages your library and settings. See [the design](docs/superpowers/specs/2026-11-12-kinora-design.md) and [the Lock Screen spike](docs/spikes/2026-11-12-lock-screen-spike.md).

The plug-in interface is private to macOS, so a future macOS update could change or close it. Kinora checks what it needs at runtime and tells you plainly if something stops working.

## Requirements

macOS 26 or later. Developed and tested on macOS 27 on Apple silicon. macOS 26 and Intel Macs are best effort.

## Install

There is no release yet. Build it yourself (below), or read [installing and the trust tradeoffs](docs/INSTALL.md) of an app that isn't notarized.

## Build

```sh
./build.sh            # release build, universal -> build/Kinora.app
./build.sh dev        # debug build for this Mac
./build.sh test       # run the tests
./build.sh install    # dev build, installed to ~/Applications
```

Builds are signed ad hoc unless you run `Tools/setup-signing.sh` once, which creates a stable local signing identity so macOS remembers Kinora's permissions across rebuilds.

## License

Kinora is free software under the GNU General Public License, version 3 or later. See [LICENSE](LICENSE). The build and signing scripts are adapted from [Vorssaint](https://github.com/vorssaint/vorssaint-utils), also GPL-3.0-or-later.

Kinora is not affiliated with Apple.
