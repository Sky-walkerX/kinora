# What the other Mac live wallpaper apps miss

Date: 2026-11-12.

Sources:
- the issue trackers of [WallpaperMachine](https://github.com/MMFoundation/WallpaperMachine) and [Aerial 4](https://github.com/AerialScreensaver/Aerial), sorted by reactions and comments
- their READMEs and release notes
- three Reddit threads: the Aerial 4 launch on r/macapps, the Loopr launch on r/MacOS, and "custom videos for the Sonoma aerials" on r/MacOS
- the list of Apple's own wallpaper types on macOS 27.0.1

Question: what is missing in those apps that would make people switch to Kinora?

## Where the field stands

| | Aerial 4 | WallpaperMachine | Muro | Kinora (milestone 2) |
|---|---|---|---|---|
| License | MIT | GPL-3.0 | PolyForm Shield since 2026-09-21 | GPL-3.0 |
| Desktop rendering | `com.apple.wallpaper` plug-in | app windows | app windows | `com.apple.wallpaper` plug-in |
| Lock Screen | yes, plug-in | experimental, off by default | yes, plug-in | yes, plug-in |
| Signed and notarized | yes | yes, since 1.8.3 | no | **no** (owner's choice) |
| Content | Apple's aerials, community and paid packs, your own videos, live streams | Wallpaper Engine scenes, video and web, Workshop, pixiv, your own files | its own catalogue, your own videos | your own videos |

Both rivals are active: WallpaperMachine ships changes within days of a request, and Aerial within a week or two. Out-shipping them feature by feature is not a plan.

## What users ask for, and who already has it

1. **Battery and heat.**
   - Aerial thread: "custom 4K/HDR clips can quietly turn a screensaver app into a small background video player".
   - Loopr was built around "live on lock, still on desktop, no overhead". Its author found Aerial's 3-second unlock transition "confusing or didn't work properly".
   - WallpaperMachine shows power draw. Nobody makes "live on the Lock Screen, still on the desktop" the easy default.
2. **Disk space.**
   - "the 4K HDR videos quietly eat disk space over time" (Aerial thread).
   - Apple's aerials take 50.5 GB (r/mac).
   - Aerial #144: paid packs ignore the chosen cache location.
3. **Reliability on wake and across displays.**
   - Aerial: #134 (an external display stops after sleep), #127, #141, and #205 (memory, then crashes).
   - WallpaperMachine: #30 (multi-display freeze), #33, #109 (the Lock Screen reverts), #169 (menu bar and Dock show different images), #173 (window trails in Mission Control).
4. **Your own content.**
   - "Own video is crazy value" (Aerial thread).
   - On a Mac, a photo can only be a still wallpaper. Apple's wallpaper types on macOS 27.0.1 include no depth, parallax or spatial option, though iPhone's Lock Screen has spatial scenes.
5. **Trust in the install.**
   - "Not signed. Yeah, no." was the reply to the unsigned Loopr.
   - WallpaperMachine moved to notarized builds.
   - Kinora stays unsigned unless the owner changes course; this cuts against us.
6. **Wallpaper Engine content.** WallpaperMachine covers it well, but needs a Steam account that owns Wallpaper Engine for scenes, and Steam login problems are its most-discussed issues (#104, #186).

## Gaps that could make people switch

Ranked by evidence and by how well Kinora's native plug-in fits.

| Gap | Evidence | Who has it | Fit for Kinora |
|---|---|---|---|
| **Living Photos**: a still photo becomes a subtly moving wallpaper (depth parallax, slow drift, sky motion) on the desktop and Lock Screen | Strong demand for personal content; iPhone has spatial scenes and the Mac has nothing | Nobody on Mac | High: Metal in the plug-in, no video files, low power |
| **Battery-first by default**: plays on the Lock Screen and for a few seconds after unlock, then holds a still, with a live cost shown per wallpaper | Loopr built a whole app around it; battery fears in every thread | Partly (Loopr; WallpaperMachine's pause rules) | Already implemented as an option; make it the polished default |
| **Disk-light library**: every video converted once to the display's size and an efficient bitrate, with the saving shown | Disk complaints for Aerial and Apple's aerials | Nobody does it automatically | High: milestone 3 conversion, plus a "saved X GB" readout |
| **Generative wallpapers**: Metal shaders and live-data scenes (sky, sun, weather) that never loop visibly | Wallpaper Engine scenes are popular but need WE and Steam; indie Metal and live-Earth apps launch to interest | WallpaperMachine (via WE, windows only), paid Narwall | High: milestone 4, native in the plug-in |
| **An open format for creators**: anyone can publish a native Mac wallpaper (shader or scene) with no Steam and no purchase | Workshop friction; the Aerial community packs | Nobody | Medium: builds on milestones 4 and 5 |
| **Reliability as a feature**: per-display surfaces from macOS itself, self-repair, a diagnostics export | Many wake and multi-display bugs in both rivals | Aerial partly | Medium: mostly done; needs multi-display testing |

**Against Kinora:** no notarization. Muro and Loopr show unsigned apps still get users, but "Not signed. Yeah, no." is a common reaction. Revisit the Developer ID once Kinora has traction, for example funded through sponsorship.
