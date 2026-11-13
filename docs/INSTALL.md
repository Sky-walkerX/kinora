# Installing Kinora, and what "not notarized" means

Kinora has no release yet. This page describes how releases will be installed and the trust tradeoffs of shipping without Apple's notarization, so the owner can decide on signing before the first one.

## Ways to install

- **Build it yourself.** `./build.sh install` builds Kinora on your Mac and installs it to `~/Applications`. Nothing is downloaded, so macOS doesn't quarantine it, and you can read every line first. Run `Tools/setup-signing.sh` once so rebuilds keep macOS's approvals.
- **GitHub release (planned).** A zip of `Kinora.app` with its SHA-256 next to it. `Tools/package-release.sh` prepares one locally; nothing is published until the owner says so.
- **Homebrew (planned).** `brew install --cask sky-walkerx/tap/kinora`, from a personal tap. The cask is prepared in `packaging/homebrew/`, not published. The official `homebrew/cask` repository doesn't accept apps that aren't notarized.

## The trust tradeoffs

Kinora is signed with a stable self-signed certificate ("Kinora Local Signing"), or ad hoc, and is **not notarized**. Notarization needs a paid Apple Developer ID.

What that means for someone installing a downloaded copy:

- **First launch is blocked.** macOS says it can't check Kinora for malicious software. The user opens System Settings › Privacy & Security and chooses **Open Anyway**, once. Onboarding explains this.
- **Apple hasn't scanned it.** Notarization runs an automated malware scan and lets Apple revoke a build later. Without it, users rely on the source being public, the build being reproducible, and the checksum matching.
- **Signatures prove less.** A self-signed certificate shows that every build came from the same key, so macOS keeps Kinora's permissions across updates, but it doesn't identify a person or company to macOS.
- **Some people won't install it.** Reactions like "Not signed. Yeah, no." are common (see the competitor research). That costs users, not safety.
- **Unverified: the plug-in after Open Anyway.** Whether a quarantined, self-signed copy's wallpaper plug-in launches inside WallpaperAgent after Open Anyway is not yet tested. It must be checked before the first release (owner checklist below). If it fails, onboarding will need a documented re-enable step.

What users can check themselves:

```sh
shasum -a 256 Kinora-0.1.0.zip          # compare with SHA256SUMS on the release page
codesign -dv --verbose=2 /Applications/Kinora.app   # "Kinora Local Signing" or "adhoc"
spctl -a -vv /Applications/Kinora.app   # "rejected" is expected without notarization
```

Removing the quarantine flag with `xattr -dr com.apple.quarantine` skips Gatekeeper entirely. Kinora's documentation doesn't recommend it; Open Anyway is the supported path.

## Revisiting Developer ID and notarization

A Developer ID costs 99 USD a year. With it, releases could be signed and notarized, first launch would open normally, and the official Homebrew cask would be possible. Options to discuss with the owner:

1. Stay self-signed and explain it well (today's choice).
2. Fund a Developer ID through GitHub Sponsors once Kinora has users, and switch releases to it. The bundle identifiers stay the same, so existing users keep their wallpaper settings; macOS asks once more for any permissions, because the signing identity changes.
3. Notarize only, keeping everything else.

Nothing will be bought or any signing material uploaded without the owner's explicit decision. Release signing in CI would need the certificate in repository secrets, which also needs that decision.

## Uninstalling

Use **Settings › Advanced › Remove Kinora** before deleting the app: it puts back the wallpaper you had (when Kinora is still showing) and removes Kinora's section from System Settings. Or run `Tools/uninstall.sh` (add `--delete-library` to remove the library too). Then drag Kinora to the Bin. Homebrew users: `brew uninstall --cask kinora`, or `--zap` to remove the library as well.
