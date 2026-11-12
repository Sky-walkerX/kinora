# Spike: live video on the macOS Lock Screen

Date: 2026-11-12. Machine: Mac17,3 (Apple silicon, built-in 2940x1912 display), macOS 27.0.1 (26A434), Swift 6.4.2.

Question: can a third-party app play video on the macOS 27 Lock Screen, under the system clock and login controls and above the system wallpaper?

**Result: possible.** A wallpaper plug-in on Apple's own `com.apple.wallpaper` ExtensionKit point played video under the date, clock and login controls, then kept playing as the desktop wallpaper after unlock. It used no private entitlement and no code from other wallpaper apps.

The spike code is throwaway. It is kept in `2026-11-12-lock-screen/` as reference, next to the probe tools used to read Apple's interfaces.

## Options

| Option | Tried | Result |
|---|---|---|
| Vorssaint's private CGS Space at absolute level 400 (`NotchOverlaySpace`) | No | Draws over the Lock Screen, so over the clock. Kept only as a last-resort fallback idea. |
| A `com.apple.wallpaper` plug-in hosted by WallpaperAgent, the mechanism Apple's aerials use | Yes | Works. Details below. |

## Evidence

Observed:

- **Owner's screen recording (21 s, 60 fps).** For about 8 s, the locked screen shows the test video moving under the date, clock, avatar and password hint. After unlock, the same video keeps playing as the desktop wallpaper behind the windows. The recording is kept privately, outside this repo.
- **Three captures taken while locked.** A watcher captured the screen 4, 6 and 10 s after lock. The moving elements and the video's frame counter differ between captures. They are kept outside the repo because they show the account name.
- **Plug-in log.** Acquire happened at the WallpaperAgent restart, with `isPreview:false`, `presentationMode:default` and `activityState:active`. At lock it logged an `update` with `presentationMode:locked`, and at unlock an `update` with `presentationMode:default`.
- **WallpaperAgent log:**
  - `Create new wallpaper in runtime ... provider=dev.spike.LiveWallpaperSpike.Wallpaper`
  - `makeWallpaper for '[extension] dev.spike...'`
  - a RunningBoard launch of the plug-in
  - after snapshot support: `Exporting wallpaper ... writing` then `END`, with no error
- **System Settings › Wallpaper** listed the plug-in's own section, "Live Wallpaper Spike", with a video-badged tile. Owner's screenshot.
- **Cost.** Sampled with `top` every ~8 s for 2 min while the owner worked; the data is in `2026-11-12-lock-screen/*.csv`.
  - Spike plug-in: 2.09% of one core on average (1.4 to 3.6), top POWER about 2.5, 13 MB, playing 2560x1664 HEVC at 30 fps through plain `AVPlayer`.
  - Apple's aerial, in its normal desktop state: 0.0% and 15 MB. It settles on a still after unlock.

Inferred, not verified:

- The exported snapshot is what the pre-login screen shows after a restart. Not tested; it needs a reboot.
- The `com.apple.wallpaper.appexpt` file lists `com.apple.private.wallpaper.extension` under `EXRequiredEntitlements`, but nothing enforces it on 27.0.1. A future macOS may enforce it.

## How it works

### Registration

- The plug-in is `Host.app/Contents/Extensions/X.appex` with:
  - `CFBundlePackageType` = `XPC!`
  - `EXAppExtensionAttributes.EXExtensionPointIdentifier` = `com.apple.wallpaper`
  - the `com.apple.security.app-sandbox` entitlement and nothing else
  - an ad hoc signature, which AMFI logs as non-fatal
- LaunchServices registers the plug-in only after the host app has been launched once. Then `pluginkit -e use -i <bundle id>` enables it.
- The plug-in point's definition is `/System/Library/ExtensionKit/ExtensionPoints/com.apple.wallpaper.appexpt`. WallpaperAgent hosts it, and also a `com.apple.wallpaper.development` point that has no definition file on this system.

### Entry point

- Link with `-Xlinker -e -Xlinker _NSExtensionMain`, as Apple's wallpaper plug-ins do.
- Foundation's `NSExtensionMain` sets `ExtensionMain.shared` and then calls the Swift `@main` type: `struct X: AppExtension` with `ConnectionHandler`.
- Without that entry point, `_EXRunningExtension._shared` traps on a nil force-unwrap.

### Protocol

The plug-in exports an NSXPC interface. The full list was read from `WallpaperExtensionKit.WallpaperExtensionXPCProtocol` and `WallpaperExtensionProxyXPCProtocol` with `protocol_copyMethodDescriptionList` and `_protocol_getMethodTypeEncoding`; see `probes/objcdump.m` and `probes/extenc.m`. The calls that matter:

- `acquireWithId:request:reply:`: `(WallpaperIDXPC, WallpaperCreationRequestXPC) -> (WallpaperRemoteContextXPC?, NSError?)`
- `updateWithId:request:reply:`: `(WallpaperIDXPC, WallpaperUpdateRequestXPC) -> NSError?`
- `invalidateWithId:reply:`
- `snapshotWithId:reply:`: returns `WallpaperSnapshotXPC?`
- `provideSettingsViewModelsWithContentTypes:reply:`: returns `WallpaperSettingsViewModelsXPC?`
- `selectedChoicesDidChangeFor:reply:`, `isChoiceDownloadedWith:reply:`, and the download, shuffle, migration, debug and context-menu calls

The host side, `WallpaperExtensionProxyXPCProtocol`, offers:

- `updateSettingsViewModels:reply:`
- `invalidateSnapshotsWithReply:`
- `pingWithId:`
- `requestReadOnlyAccessTo:reply:`

### Message objects

Each object is `NSSecureCoding` and stores its Swift value as JSON `Data` under a key named after the type. Every subclass must override `supportsSecureCoding`, or NSXPC drops the message.

| Class | Key | Payload |
|---|---|---|
| `WallpaperIDXPC` | `WallpaperID` | `{"id": "<UUID>"}` |
| `WallpaperRemoteContextXPC` | `UInt32` | the `CAContext` `contextId` as a JSON number |
| `WallpaperUpdateRequestXPC` | `WallpaperUpdateRequest` | see the request fields below |
| `WallpaperSettingsViewModelsXPC` | `WallpaperSettingsViewModels` | see the view-model schema below |
| `WallpaperContentTypeSetXPC` | `Set<ContentType>` | e.g. `[1,0]` |
| `WallpaperChoiceIDXPC` / `WallpaperChoiceIDsXPC` | `ID` / `Array<ID>` | |
| `WallpaperCreationRequestXPC` | `files` (array of `NSSecurityScopedURLWrapper`), `cacheDirectory`, `codable` (JSON) | |
| `WallpaperSnapshotXPC` | `surface` | over `NSXPCCoder` only, as `IOSurfaceCreateXPCObject(surface)` |

Field names come from the Swift reflection metadata in WallpaperTypes, WallpaperExtensionKit and WallpaperFoundation (`probes/swiftfields.c`). The coding keys and formats come from feeding Apple's own classes spy coders (`probes/spycoder.m`, `probes/xpcspy.m`).

Request fields:

- **Creation request:** `descriptor` (`configuration` as base64 Data, `files`, `optionValues`), `destination`, `isPreview`, `presentationMode`, `activityState`, `systemAppearance`, `debugBackgrounds`.
  - `destination` holds `size` (`[w, h]` in points), `scaleFactor`, `directDisplayID` and `colorSpace` (a base64 plist).
- **Enum encoding:** cases are encoded as `{"caseName": {}}`.
  - `presentationMode`: `default`, `locked`, `idle`
  - `activityState`: `active`, `suspended`
  - `systemAppearance`: `light`, `dark`
- **Update request:** `presentationMode`, `activityState`, `systemAppearance`, `destination`, `debugBackgrounds`.

Rendering: on acquire, create a context with `[CAContext remoteContextWithOptions:@{}]` (private QuartzCore class), set its `layer`, and reply with its `contextId`. WallpaperAgent hosts that layer.

### Settings view models

These are the System Settings tiles. The shape below passes Apple's own decoder:

```json
{"desktop": {"groups": [{"id": {"id": "group.id"}, "localizedName": "Kinora", "disposability": {"none": {}},
  "sortID": {"id": "kinora"}, "shouldHideItemLabels": false, "sortOrder": 0,
  "items": [{"id": {"id": "item.id"}, "localizedName": "Name", "thumbnail": {"image": {"url": "file:///...png"}},
    "choice": {"id": {"descriptor": {"provider": "<plug-in bundle id>", "files": [], "configuration": "<base64>"}},
               "localizedDescription": "Name", "thumbnail": {"image": {"url": "file:///...png"}}, "isDownloaded": true, "options": []},
    "contentBadge": {"video": {}}, "showInTopLevel": true, "sortOrder": 0, "disposability": {"none": {}}}]}],
  "refreshPolicy": {"default": {}}, "isModificationDisabled": false},
 "screenSaver": { "...same shape..." }}
```

More fields exist and are optional: `options` for pickers, toggles and colours (Apple's aerials use them for variant and shuffle), `contextMenu`, `toolTip`, `subgroupID`, `choiceRequest`, plus `WallpaperShuffleFrequency`.

### Selection

- The wallpaper store is `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`, with nodes `AllSpacesAndDisplays`, `Displays`, `Spaces` and `SystemDefault`. Each holds `Desktop`, `Idle` (the screen saver) and sometimes `Linked`, with `Content.Choices[]` of `{Provider, Configuration, Files}`.
- `Provider` equals the plug-in's bundle ID.
- The spike selected itself by writing `AllSpacesAndDisplays.Desktop` and restarting WallpaperAgent. The restart makes the wallpaper blink once.
- An older `Index_v2.plist` sits next to the store, last written in September. On this Mac `Index.plist` is the live one.

## Not established

- When, if ever, WallpaperAgent sends `activityState: suspended`. It never did in 2 minutes of normal work with windows covering the desktop, so Kinora needs its own coverage check.
- Whether the plug-in launches from a downloaded copy that is quarantined and ad hoc or self-signed, after the user approves the app with Open Anyway.
- Multiple displays, per-Space choices, the screen saver (`idle`), and the pre-login screen after a restart.
- Whether WebKit runs inside the sandboxed plug-in, for web wallpapers.
- A way to apply a selection without restarting WallpaperAgent. System Settings does it, so a path exists.
  - WallpaperAgent does **not** watch its store. Atomic or in-place writes to `Index.plist` change nothing until it restarts. Tested 2026-11-12.
  - A quiet apply therefore needs the XPC call System Settings makes. Where to look:
    - WallpaperAgent's mach services `com.apple.wallpaper` and `com.apple.wallpaper.public`
    - the strings `desktopWallpaperUserSettingsUpdate`, `storeIndexUpdate`, `userSettingsIntents` and `settingsObservationRequest`
    - WallpaperSettingsUI and Wallpaper.framework, which make the call on System Settings' side

## Tooling notes

- Wallpaper frameworks live only in the dyld shared cache. The probes `dlopen` them and read the Objective-C runtime, Swift reflection sections and instruction bytes in memory.
- WallpaperAgent itself is a file on disk and opens in REA (Ghidra 12.1.4) after `lipo -thin arm64e`.
- In zsh, `log` is a shell builtin. Use `/usr/bin/log show`.
