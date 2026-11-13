#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 The Kinora Contributors
#
# Removes Kinora by hand, the same way Settings › Advanced › Remove Kinora does:
#
#   1. If Kinora is still the wallpaper, puts back the wallpaper store Kinora backed up before
#      its first change, and restarts WallpaperAgent so it reads it.
#   2. Switches off and unregisters the wallpaper plug-in, so System Settings has no Kinora section.
#   3. With --delete-library, deletes ~/Library/Application Support/Kinora and Kinora's preferences.
#
# Then drag Kinora.app to the Bin. Your own videos and photos are never touched.
set -euo pipefail

PLUGIN=io.github.sky-walkerx.kinora.wallpaper
STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store"
LIBRARY="$HOME/Library/Application Support/Kinora"
APP=${KINORA_APP:-/Applications/Kinora.app}
[[ -d $APP ]] || APP="$HOME/Applications/Kinora.app"

if [[ -f "$STORE/Index.plist" ]] && plutil -p "$STORE/Index.plist" | grep -q "$PLUGIN"; then
    restored=0
    for name in Index.plist Index_v2.plist; do
        if [[ -f "$LIBRARY/Backups/original-$name" ]]; then
            cp "$LIBRARY/Backups/original-$name" "$STORE/$name"
            restored=1
        fi
    done
    if (( restored )); then
        print "Restored the wallpaper you had before Kinora."
    else
        print "Kinora is the wallpaper but has no backup; pick another wallpaper in System Settings."
    fi
fi

pluginkit -e ignore -i "$PLUGIN" 2>/dev/null || true
[[ -d "$APP/Contents/Extensions/KinoraWallpaper.appex" ]] && pluginkit -r "$APP/Contents/Extensions/KinoraWallpaper.appex" 2>/dev/null || true
[[ -d $APP ]] && /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
killall WallpaperAgent 2>/dev/null || true
print "Unregistered the wallpaper plug-in."

if [[ ${1:-} == --delete-library ]]; then
    rm -rf "$LIBRARY"
    defaults delete io.github.sky-walkerx.kinora 2>/dev/null || true
    print "Deleted Kinora's library and preferences."
fi
print "Now drag Kinora to the Bin."
