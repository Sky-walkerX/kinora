#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 The Kinora Contributors
#
# SPIKE: builds WebProbe and runs it three ways: signed with exactly the wallpaper plug-in's
# entitlements, with those plus outgoing network access, and unsandboxed. The page is put where
# the plug-in may read, ~/Library/Application Support/Kinora/WebProbe/, and removed afterwards.
#
#   docs/spikes/2026-11-22-webkit-probe/run.sh [output folder]
#
# Prints one JSON line per scenario ("WEBPROBE {...}") and keeps them, with WebKit's and the
# sandbox's log lines, in the output folder. It shows two small windows for a few seconds and
# changes no settings. The sandbox containers it creates are removed at the end.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=${1:-$HERE/build}
PAGE_DIR="$HOME/Library/Application Support/Kinora/WebProbe"
PREFIX=io.github.sky-walkerx.kinora.webprobe
mkdir -p "$OUT"
: > "$OUT/results.jsonl"

cleanup() {
    rm -rf "$PAGE_DIR"
    for variant in plugin network none; do
        # macOS may protect containers; a leftover one is harmless and named after the probe.
        rm -rf "$HOME/Library/Containers/$PREFIX.$variant" 2>/dev/null || echo "note: left $HOME/Library/Containers/$PREFIX.$variant"
    done
}
trap cleanup EXIT

swiftc -swift-version 5 -O -parse-as-library "$HERE/WebProbe.swift" -o "$OUT/WebProbe" \
    -framework AppKit -framework WebKit -framework QuartzCore || exit 1

mkdir -p "$PAGE_DIR"
cp "$HERE/page.html" "$PAGE_DIR/index.html"

entitlements() { # variant -> entitlements file
    local file="$OUT/$1.entitlements"
    case $1 in
        plugin) cp "$ROOT/Resources/Wallpaper/KinoraWallpaper.entitlements" "$file" ;;
        network)
            cp "$ROOT/Resources/Wallpaper/KinoraWallpaper.entitlements" "$file"
            /usr/libexec/PlistBuddy -c "Add :com.apple.security.network.client bool true" "$file" >/dev/null ;;
        none) printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' > "$file" ;;
    esac
    printf '%s\n' "$file"
}

for variant in plugin network none; do
    app="$OUT/WebProbe-$variant.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$OUT/WebProbe" "$app/Contents/MacOS/WebProbe"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$PREFIX.$variant</string>
<key>CFBundleExecutable</key><string>WebProbe</string>
<key>CFBundleName</key><string>WebProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
    # Signed as the plug-in is: ad hoc, hardened runtime, the variant's entitlements.
    codesign --force --sign - --options runtime --entitlements "$(entitlements $variant)" "$app" || exit 1
    echo "== $variant: $(codesign -d --entitlements - --xml "$app" 2>/dev/null | tr -d '\n' | grep -o 'com.apple.security[a-z.-]*' | tr '\n' ' ')"
    started=$(date "+%Y-%m-%d %H:%M:%S")
    # The probe stops itself after 120 s; a blocked main thread can't, so a watchdog kills it at 150 s.
    "$app/Contents/MacOS/WebProbe" "$PAGE_DIR/index.html" >"$OUT/$variant.stdout" 2>"$OUT/$variant.stderr" &
    probe=$!
    ( sleep 150; kill -9 $probe 2>/dev/null && echo "   watchdog: killed the $variant probe after 150 s" ) &
    watchdog=$!
    wait $probe; status=$?
    kill $watchdog 2>/dev/null; wait $watchdog 2>/dev/null
    echo "   exit status $status"
    grep '^WEBPROBE' "$OUT/$variant.stdout" | while IFS= read -r line; do
        echo "$line"
        printf '{"variant":"%s",%s\n' "$variant" "${line#WEBPROBE \{}" >> "$OUT/results.jsonl"
    done
    [ $status -eq 0 ] || printf '{"variant":"%s","event":"exit","status":%d}\n' "$variant" "$status" >> "$OUT/results.jsonl"
    /usr/bin/log show --start "$started" --style compact \
        --predicate 'process == "WebProbe" OR process BEGINSWITH "com.apple.WebKit" OR (process == "kernel" AND eventMessage CONTAINS "WebProbe")' \
        2>/dev/null | grep -iE "sandbox|deny|denied|crash|terminat|error|fail" | tail -80 > "$OUT/$variant.log" || true
    echo "   log lines about sandbox or errors: $(wc -l < "$OUT/$variant.log" | tr -d ' ')"
    # What the sandbox refused WebKit's processes, and how a WebContent process ended, if it crashed.
    /usr/bin/log show --start "$started" --style compact --predicate 'eventMessage CONTAINS "deny" AND eventMessage CONTAINS "WebKit"' \
        2>/dev/null | grep -v "^Timestamp" | sed -E 's/^.*(deny\([0-9]+\))/\1/' | sort | uniq -c | sort -rn | head -25 > "$OUT/$variant.denials" || true
    echo "   distinct sandbox denials for WebKit processes: $(wc -l < "$OUT/$variant.denials" | tr -d ' ')"
    head -8 "$OUT/$variant.denials" | sed 's/^/     /'
    find "$HOME/Library/Logs/DiagnosticReports" -name '*WebContent*' -newermt "$started" 2>/dev/null | head -3 | while read -r report; do
        echo "   crash report: $(basename "$report")"
        grep -aE '"(exception|termination|crashed|faultingThread|asi)"|Termination Reason|Exception Type|Crashed Thread|abort|ASI' "$report" | head -8 | cut -c1-300 | sed 's/^/     /'
        cp "$report" "$OUT/$variant-$(basename "$report")"
    done
done
