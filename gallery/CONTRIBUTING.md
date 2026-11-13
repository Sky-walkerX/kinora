# Adding a wallpaper to the gallery

Every entry is reviewed by a person before it is merged. The review protects the people who use Kinora and the people who made the footage.

## What can be listed

Only work that anyone may redistribute, including inside a wallpaper app, with credit where the license asks for it:

| License | Typical sources | Credit |
|---|---|---|
| Public domain (`LicenseRef-Public-Domain`) | NASA imagery and video, unless it says otherwise | Give it anyway: "NASA" or the centre |
| `CC0-1.0`, `PDDL-1.0` | Wikimedia Commons, contributors | Optional |
| `CC-BY-4.0` | ESA, ESO, Blender open movies, contributors | Required, exactly as the source asks |
| `CC-BY-SA-4.0` | Wikimedia Commons, contributors | Required |

Not accepted:

- Pexels and Pixabay: their terms forbid wallpaper apps from redistributing their content.
- Anything "free for personal use", "no derivatives" (ND) or "non-commercial" (NC).
- Wallpaper Engine Workshop items, unless the author licensed them as above and says so where they published them.
- Footage with people who can be recognised, unless the source says releases were obtained.
- NASA material that credits a third party (some imagery is copyrighted by partners). Check the item's own page.

## The review checklist

1. **Rights.** The `source` page states the license, and the license is in the table above. Save a link to that statement in the pull request.
2. **Credit.** `attribution` matches what the source asks for, word for word where it gives wording.
3. **Package.** It passes Kinora's own checks: drop it on Kinora's window before opening the pull request.
4. **Quality.** At least 1920 × 1080; loops without a visible jump for video; no watermarks or burned-in text unless they are part of the work; ultrawide welcome.
5. **Size.** As small as it can be while looking right. HEVC at a sensible bitrate; Kinora converts for the user's display anyway.
6. **Catalog.** `sha256` and `bytes` are those of the released zip; `download` points at this repository's release.

## Steps

1. Put the package folder in `packages/<id>/`, with its `wallpaper.json`, media and a `preview.jpg` of at most 10 MB.
2. Open a pull request with the rights link from step 1.
3. After review, a maintainer zips the package, attaches it to a release, and adds the catalog entry with the release's URL, digest and size.

Removal requests from rights holders are handled first, and the entry is removed while they are looked at.
