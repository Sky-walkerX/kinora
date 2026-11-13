#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 The Kinora Contributors
#
# Builds a release candidate locally and prepares, but does not publish, what a GitHub release
# and the Homebrew tap would need:
#
#   dist/Kinora-<version>.zip     the app, zipped with ditto so signatures and links survive
#   dist/SHA256SUMS               its checksum
#   dist/kinora.rb                the cask for Sky-walkerX/homebrew-tap, filled in
#
# Nothing is uploaded. Publishing a release or the tap needs the owner's go-ahead.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Kinora.app/Contents/Info.plist)
mkdir -p dist
ZIP="dist/Kinora-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Kinora.app "$ZIP"
SUM=$(shasum -a 256 "$ZIP" | awk '{print $1}')
print "$SUM  Kinora-$VERSION.zip" > dist/SHA256SUMS
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SUM/" packaging/homebrew/kinora.rb.template > dist/kinora.rb
codesign -dv build/Kinora.app 2>&1 | grep -E "Authority|Signature|TeamIdentifier" || true
print "Prepared $ZIP ($SUM). Not published."
