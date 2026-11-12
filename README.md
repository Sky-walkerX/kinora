# Kinora

Live wallpapers for your Mac, on the desktop and on the Lock Screen. Free and open source.

> **Status:** early development. There is no release yet.

## What it does

- Plays video and animated wallpapers on the desktop, the Lock Screen and the screen saver, on every display.
- Shows its wallpapers in System Settings › Wallpaper, next to Apple's.
- Keeps playing after you quit the app, because macOS itself runs Kinora's renderer.
- Pauses when you can't see the wallpaper, on battery and in Low Power Mode, and shows what it costs.
- No account, no paywall, no telemetry. It only goes online when you ask it to.

## How it works

Kinora ships a wallpaper plug-in for macOS's own wallpaper system, the same mechanism Apple's aerials use. WallpaperAgent loads the plug-in and draws what it renders under the clock on the Lock Screen and behind your windows on the desktop. The Kinora app manages your library and settings. See [the design](docs/superpowers/specs/2026-11-12-kinora-design.md) and [the Lock Screen spike](docs/spikes/2026-11-12-lock-screen-spike.md).

The plug-in interface is private to macOS, so a future macOS update could change or close it. Kinora checks what it needs at runtime and tells you plainly if something stops working.

## Requirements

macOS 26 or later. Developed and tested on macOS 27 on Apple silicon. macOS 26 and Intel Macs are best effort.

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
