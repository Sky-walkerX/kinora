#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 The Kinora Contributors
#
# Writes Metadata.appintents into an app bundle, so Shortcuts lists Kinora's actions.
#
#   Tools/app-intents-metadata.sh path/to/Kinora.app
#
# Xcode runs Apple's appintentsmetadataprocessor as a build step; SwiftPM has none. The
# processor reads the constant values the Swift compiler records for App Intents types, so this
# builds the app's module once more, in its own scratch folder, with those values switched on,
# then runs the processor the way Xcode does. Anything missing leaves the app without the
# metadata and says so: kinora:// links keep working either way.
set -euo pipefail

ROOT=${0:A:h:h}
APP=${1:?usage: $0 path/to/Kinora.app}
WORK="$ROOT/.build/app-intents"
RESOURCES="$APP/Contents/Resources"
note() { echo "note: $*; Shortcuts actions left out (kinora:// links still work)"; exit 0; }

xcrun --find appintentsmetadataprocessor >/dev/null 2>&1 || note "this Xcode has no appintentsmetadataprocessor"
mkdir -p "$WORK"
# Xcode's default list of protocols whose conformances the compiler records (SWIFT_EMIT_CONST_VALUE_PROTOCOLS).
print -r -- '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]' > "$WORK/protocols.json"

swift build --product Kinora --scratch-path "$WORK/build" \
    -Xswiftc -emit-const-values \
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$WORK/protocols.json" \
    > "$WORK/build.log" 2>&1 || { tail -20 "$WORK/build.log"; note "the constant-values build failed"; }

find "$WORK/build" -name '*.swiftconstvalues' -path '*Kinora.build*' | sort > "$WORK/constvalues.txt"
[[ -s "$WORK/constvalues.txt" ]] || note "the compiler wrote no constant values"
# Absolute paths: the constant values record them, and the processor matches them.
find "$ROOT/Sources/Kinora" -name '*.swift' | sort > "$WORK/sources.txt"

SDK=$(xcrun --sdk macosx --show-sdk-path)
TOOLCHAIN=${$(xcrun --find swiftc):h:h:h}
XCODE=$(xcodebuild -version 2>/dev/null | awk '/Build version/ { print $3 }')
rm -rf "$RESOURCES/Metadata.appintents"
mkdir -p "$RESOURCES"
xcrun appintentsmetadataprocessor \
    --output "$RESOURCES" \
    --toolchain-dir "$TOOLCHAIN" \
    --module-name Kinora \
    --sdk-root "$SDK" \
    --xcode-version "${XCODE:-unknown}" \
    --platform-family macOS \
    --deployment-target 26.0 \
    --bundle-identifier io.github.sky-walkerx.kinora \
    --target-triple "$(uname -m)-apple-macos26.0" \
    --binary-file "$APP/Contents/MacOS/Kinora" \
    --source-file-list "$WORK/sources.txt" \
    --swift-const-vals-list "$WORK/constvalues.txt" \
    --compile-time-extraction \
    --deployment-aware-processing \
    --no-app-shortcuts-localization > "$WORK/metadata.log" 2>&1 || { tail -20 "$WORK/metadata.log"; note "the metadata processor failed"; }

[[ -f "$RESOURCES/Metadata.appintents/extract.actionsdata" ]] || { tail -20 "$WORK/metadata.log"; note "the processor wrote no actions"; }
echo "included App Intents metadata ($(wc -l < "$WORK/constvalues.txt" | tr -d ' ') constant-value files)"
