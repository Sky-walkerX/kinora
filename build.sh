#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 The Kinora Contributors
#
# One command to build, test and install Kinora.
#
#   ./build.sh            release build, universal (arm64 + x86_64), signed -> build/Kinora.app
#   ./build.sh dev        debug build for this Mac only, signed            -> build/Kinora.app
#   ./build.sh test       run the KinoraKit tests
#   ./build.sh install    dev build, then install to ~/Applications and register the plug-in
#   ./build.sh clean      remove build output
#
# SwiftPM cannot produce app or .appex bundles, so this script assembles them from the
# executables SwiftPM builds. Signing uses the stable local identity from
# Tools/setup-signing.sh when it is installed, and an ad hoc signature otherwise.
set -euo pipefail

ROOT=${0:A:h}
cd "$ROOT"

VERSION="0.1.0"
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
IDENTITY="Kinora Local Signing"
KEYCHAIN="$HOME/Library/Keychains/kinora-signing.keychain-db"
OUT="$ROOT/build"
APP="$OUT/Kinora.app"
APPEX="$APP/Contents/Extensions/KinoraWallpaper.appex"

signing_identity() {
    # A listed identity is not proof codesign can use it: try a throwaway file first.
    security unlock-keychain -p kinora-signing "$KEYCHAIN" 2>/dev/null || true
    local probe; probe=$(mktemp)
    cp /bin/echo "$probe"
    if codesign --force --sign "$IDENTITY" "$probe" >/dev/null 2>&1; then printf "%s\n" "$IDENTITY"; else printf "%s\n" "-"; fi
    rm -f "$probe"
}

fill_plist() { # template destination
    sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" "$1" > "$2"
    plutil -lint -s "$2"
}

assemble() { # directory holding the Kinora and KinoraWallpaper executables
    local bin=$1
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
    cp "$bin/Kinora" "$APP/Contents/MacOS/Kinora"
    cp "$bin/KinoraWallpaper" "$APPEX/Contents/MacOS/KinoraWallpaper"
    fill_plist Resources/App/Info.plist "$APP/Contents/Info.plist"
    fill_plist Resources/Wallpaper/Info.plist "$APPEX/Contents/Info.plist"
    printf 'APPL????' > "$APP/Contents/PkgInfo"

    local id; id=$(signing_identity)
    [[ $id == "-" ]] && echo "note: signing ad hoc; run Tools/setup-signing.sh for a stable identity"
    # Sign inside out: the plug-in first, then the app that contains it.
    codesign --force --options runtime --timestamp=none --sign "$id" \
        --entitlements Resources/Wallpaper/KinoraWallpaper.entitlements "$APPEX"
    codesign --force --options runtime --timestamp=none --sign "$id" \
        --entitlements Resources/App/Kinora.entitlements "$APP"
    codesign --verify --strict --deep "$APP"
    echo "built $APP ($VERSION, build $BUILD_NUMBER, signed: $id)"
}

build_release() {
    swift build -c release --arch arm64 --arch x86_64
    assemble "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
}

build_dev() {
    swift build
    assemble "$(swift build --show-bin-path)"
}

install_dev() {
    build_dev
    local dest="$HOME/Applications/Kinora.app"
    mkdir -p "$HOME/Applications"
    # Quit a running copy so the new build is the one LaunchServices records.
    pkill -x Kinora 2>/dev/null || true
    rm -rf "$dest"
    cp -R "$APP" "$dest"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest"
    echo "installed $dest"
}

case "${1:-release}" in
    release) build_release ;;
    dev) build_dev ;;
    test) swift test ;;
    install) install_dev ;;
    clean) rm -rf "$OUT" .build ;;
    *) echo "usage: $0 [release|dev|test|install|clean]" >&2; exit 64 ;;
esac
