# kinora-gallery (staged)

This folder is the starting content for a separate `Sky-walkerX/kinora-gallery` repository. **It has not been published.** Creating that public repository needs the owner's go-ahead. Until it exists, Kinora's Gallery says "The Gallery Isn't Open Yet" and everything else works without it.

The gallery lists Kinora wallpaper packages ([format](../docs/FORMAT.md)) that anyone may redistribute. Kinora fetches `catalog.json` only when the user opens the gallery and presses Browse, and downloads only what the user picks.

## Layout once published

- `catalog.json`: the list Kinora reads, schema below. Served from `https://raw.githubusercontent.com/Sky-walkerX/kinora-gallery/main/catalog.json`.
- `packages/<id>/`: each package's source folder, reviewed by pull request.
- GitHub releases: the zipped `.kinorawallpaper` files the catalog's `download` URLs point at. Releases are free and keep large media out of git history.
- `CONTRIBUTING.md`: the review rules.

## catalog.json, schema version 1

```json
{
  "schemaVersion": 1,
  "entries": [
    {
      "id": "io.github.sky-walkerx.gallery.example",
      "version": "1.0.0",
      "name": "Example",
      "summary": "One line about it.",
      "type": "video",
      "author": "Who made it",
      "license": "CC-BY-4.0",
      "attribution": "“Example” by Who, CC BY 4.0",
      "source": "https://where.it.comes.from/",
      "download": "https://github.com/Sky-walkerX/kinora-gallery/releases/download/example-1.0.0/example.kinorawallpaper",
      "sha256": "64 lower-case hex digits of the zip's SHA-256",
      "bytes": 31457280,
      "preview": "https://raw.githubusercontent.com/Sky-walkerX/kinora-gallery/main/packages/io.github.sky-walkerx.gallery.example/preview.jpg",
      "width": 3840,
      "height": 2160,
      "tags": ["ocean"]
    }
  ]
}
```

Kinora skips any entry that breaks a rule, and shows the rest:

- `id` and `version` follow the package format; `id` is unique in the catalog.
- `license` is one of `CC0-1.0`, `CC-BY-4.0`, `CC-BY-SA-4.0`, `PDDL-1.0` or `LicenseRef-Public-Domain`; CC BY and CC BY-SA need `attribution`.
- `download` and `preview` are `https` URLs on `github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com` or `release-assets.githubusercontent.com`. Redirects anywhere else are refused.
- `sha256` is the zip's digest. A download that doesn't match is deleted, not installed.
- `bytes` is the zip's size, at most 1.1 GB. A download that grows past it is stopped.
- A schema version newer than Kinora knows makes Kinora say it needs updating.

`catalog.json` here is empty on purpose: no footage has been reviewed yet. Add entries only through the review in `CONTRIBUTING.md`.
