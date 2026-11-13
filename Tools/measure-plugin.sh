#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 The Kinora Contributors
#
# Samples the Kinora plug-in's CPU and memory, for the benchmarks in docs/BENCHMARKS.md.
#
#   Tools/measure-plugin.sh [seconds] [label]        CPU and memory every 2 s, from ps
#   sudo Tools/measure-plugin.sh [seconds] [label]   also energy, from powermetrics
#
# Writes measurements/<date>-<label>.csv and prints the averages. Keep the Mac otherwise idle,
# on the same display and power source, for runs you compare.
set -euo pipefail

SECONDS_TO_RUN=${1:-120}
LABEL=${2:-run}
PID=$(pgrep -f "KinoraWallpaper.appex/Contents/MacOS/KinoraWallpaper" | head -1 || true)
[[ -n $PID ]] || { print -u2 "The Kinora plug-in isn't running. Use a Kinora wallpaper first."; exit 1; }
mkdir -p measurements
OUT="measurements/$(date +%Y-%m-%d-%H%M)-$LABEL.csv"
print "time,cpu_percent,rss_mb" > "$OUT"
END=$(( $(date +%s) + SECONDS_TO_RUN ))
while (( $(date +%s) < END )); do
    line=$(ps -o %cpu=,rss= -p "$PID" || true)
    [[ -n $line ]] || { print -u2 "The plug-in stopped."; break; }
    print "$(date +%s),$(print $line | awk '{print $1}'),$(print $line | awk '{printf "%.1f", $2/1024}')" >> "$OUT"
    sleep 2
done
awk -F, 'NR>1 {c+=$2; m+=$3; n++} END {if (n) printf "plug-in: %.2f%% of one core, %.1f MB, %d samples\n", c/n, m/n, n}' "$OUT"
if [[ $EUID -eq 0 ]]; then
    print "Energy (powermetrics, 10 samples):"
    powermetrics --samplers tasks --show-process-energy -i 2000 -n 10 2>/dev/null | grep -E "KinoraWallpaper|WallpaperAgent" || true
fi
print "Saved $OUT"
