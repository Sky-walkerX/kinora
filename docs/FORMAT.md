# Kinora wallpaper format, version 1

A Kinora wallpaper is a folder with a `wallpaper.json` manifest and the files it names. To share one, zip the folder and give the zip the `.kinorawallpaper` extension. Anyone can make and publish one. Installing it needs no account, store, Steam or purchase: double-click it, drop it on Kinora's window, or add it with **Add Wallpapers**.

Packages carry media and settings, never code. A package can play a video, show a picture, or give one of Kinora's built-in originals new colours. It cannot bring its own shader, script or program. That rule keeps an untrusted package from running anything on your Mac.

## Example

[`examples/aurora-rose`](../examples/aurora-rose) is a complete package: Kinora's Aurora original with rose colours. It has no media files, so it is free of anyone's rights.

```json
{
  "format": "kinora.wallpaper",
  "formatVersion": 1,
  "id": "io.github.sky-walkerx.examples.aurora-rose",
  "version": "1.0.0",
  "name": "Aurora Rose",
  "summary": "Kinora's Aurora in rose and violet.",
  "author": { "name": "The Kinora Contributors", "url": "https://github.com/Sky-walkerX/kinora" },
  "license": "CC0-1.0",
  "type": "original",
  "original": { "base": "aurora", "palette": [[0.98, 0.45, 0.62], [0.55, 0.32, 0.95], [0.03, 0.02, 0.07]] },
  "compatibility": { "minimumKinora": "0.1.0" },
  "tags": ["night", "aurora"]
}
```

A video package:

```json
{
  "format": "kinora.wallpaper",
  "formatVersion": 1,
  "id": "io.github.someone.ocean-dusk",
  "version": "1.2.0",
  "name": "Ocean Dusk",
  "author": { "name": "Someone" },
  "license": "CC-BY-4.0",
  "attribution": "“Ocean Dusk” by Someone, CC BY 4.0",
  "source": "https://example.org/ocean-dusk",
  "type": "video",
  "video": { "file": "loop.mov" },
  "preview": "preview.jpg"
}
```

## Fields

| Field | Required | Meaning |
|---|---|---|
| `format` | yes | Always `kinora.wallpaper`. |
| `formatVersion` | yes | `1`. Kinora refuses versions newer than it knows, with a message, instead of guessing. |
| `id` | yes | Reverse-DNS, lower case: 2 to 8 dot-separated parts of `a-z`, `0-9` and `-`, at most 100 characters. Installing a package with an `id` already in the library replaces it in place, so playlists, schedules and the Lock Screen keep pointing at it. |
| `version` | yes | Your version of the wallpaper: up to four dot-separated numbers, such as `1.2.0`. |
| `name` | yes | At most 80 characters. |
| `summary` | no | At most 300 characters. |
| `author.name` | yes | At most 100 characters. |
| `author.url` | no | `https` only. |
| `license` | yes | An [SPDX identifier](https://spdx.org/licenses/), such as `CC0-1.0` or `CC-BY-4.0`. Use `LicenseRef-…` for anything else. |
| `attribution` | for CC BY and CC BY-SA | The credit line the license asks for, at most 500 characters. Kinora shows it with the wallpaper. |
| `source` | no | Where the work comes from, `https` only. |
| `type` | yes | `video`, `image` or `original`. |
| `video.file` | for `video` | A `.mov`, `.mp4` or `.m4v` file at the package's top level. HEVC or H.264. |
| `image.file` | for `image` | A `.heic`, `.jpg`, `.jpeg` or `.png` file at the top level. |
| `original.base` | for `original` | One of Kinora's originals: `liveSky`, `aurora`, `tide` or `lava`. |
| `original.palette` | no | Three colours, each `[red, green, blue]` from 0 to 1. |
| `preview` | no | A picture for listings: `.heic`, `.jpg`, `.jpeg` or `.png`. |
| `compatibility.minimumKinora` | no | The oldest Kinora that shows the wallpaper correctly. Older versions refuse it with a message. |
| `tags` | no | Up to 10 words of at most 32 characters. |

Unknown fields are ignored, so later versions of the format can add optional fields without breaking older Kinora.

## Limits and checks

Kinora treats every package as untrusted. Before copying anything it checks:

- **Paths.** Every file name is a plain name at the package's top level: no `/`, no `..`, no leading `~` or `.`. Subfolders, symbolic links and files marked executable are refused.
- **Contents.** The package holds `wallpaper.json`, the files the manifest names, and optionally `LICENSE`, `LICENSE.txt`, `LICENSE.md`, `README.md`, `README.txt` or `CREDITS.txt`. Anything else is refused.
- **Sizes.** Manifest at most 64 KB; video at most 1 GB; picture at most 100 MB; preview at most 10 MB; each document at most 256 KB; the whole package at most 1.1 GB.
- **Archives.** A zip is measured with `zipinfo` before it is opened: at most 32 entries and 1.1 GB uncompressed, so a small zip cannot expand to fill the disk. It is opened with `ditto` into Kinora's own work folder, and anything that came out as a link is refused.
- **Media.** A video must open in AVFoundation, have a video track, be at most 8192 pixels on its longest side and at most 10 minutes long. A picture must be at most 200 megapixels. Videos are converted once for your display, like any import; large pictures are stored once at your display's size.
- **Text.** No control characters in names and credits.

The installed copy lives in Kinora's library. The package you installed from is not changed.

## The gallery's extra rules

The [gallery](../gallery/README.md) lists only packages whose license allows anyone to redistribute them, inside a wallpaper app: `CC0-1.0`, `CC-BY-4.0`, `CC-BY-SA-4.0`, `PDDL-1.0`, or `LicenseRef-Public-Domain` for public-domain works such as most NASA footage. CC BY and CC BY-SA packages must carry their credit line. The app checks this again when it installs a gallery download, and checks that the downloaded package's `id` and license match the gallery's listing and that its SHA-256 matches.

## Making a package

1. Put your video, or picture, in a folder with a `wallpaper.json` like the ones above.
2. For a video that loops, make the last frame lead into the first. Kinora plays it back to back without a gap.
3. Zip the folder's contents or the folder itself, and rename the zip to `Name.kinorawallpaper`.
4. Drop it on Kinora's window to check it. Kinora says exactly which rule a package breaks.

## Versioning

`formatVersion` changes only when a change would make older Kinora show a package wrongly. New optional fields do not change it. Kinora 0.1 reads version 1.
