#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
# Copyright (C) 2026 The Kinora Contributors
#
# Adapted from Vorssaint's Tools/setup-signing.sh.
#
# Creates a stable, self-signed code-signing identity named "Kinora Local Signing" in a
# dedicated keychain. build.sh uses it automatically, so every build carries the same
# signature and macOS keeps any permissions it granted Kinora across rebuilds and updates.
#
# Free, offline and idempotent: re-running is a no-op once a working identity exists.
# It does not replace Apple notarization. Downloaded builds still need one approval in
# System Settings > Privacy & Security > Open Anyway on first launch.
#
# Release builds must use the same certificate, so keep the exported .p12 safe (outside
# git) once releases begin.
set -euo pipefail

IDENTITY="Kinora Local Signing"
KC="$HOME/Library/Keychains/kinora-signing.keychain-db"
KCPASS="kinora-signing"

# find-identity also lists certificates codesign later rejects, and -v hides every
# self-signed one, so ask codesign itself, on a throwaway copy.
identity_can_sign() {
    local probe signed=1
    # The keychain locks after every reboot, and a locked keychain cannot sign.
    security unlock-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
    probe="$(mktemp)"
    cp /bin/echo "$probe"
    codesign --force --strip-disallowed-xattrs --sign "$IDENTITY" "$probe" >/dev/null 2>&1 && signed=0
    rm -f "$probe"
    return $signed
}

if identity_can_sign; then
    print "Signing identity '$IDENTITY' is already installed."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 -nodes \
    -subj "/CN=$IDENTITY/O=The Kinora Contributors" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
# The stock /usr/bin/openssl is LibreSSL, which rejects OpenSSL 3's -legacy flag, while
# OpenSSL 3's defaults are newer than what security(1) imports reliably. These three
# algorithms work with both and produce the same portable file.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout pass:"$KCPASS" -name "$IDENTITY" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 || {
    print -u2 "openssl pkcs12 could not export the identity."
    exit 1
}

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"            # no auto-lock
security unlock-keychain -p "$KCPASS" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$KCPASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
EXISTING=$(security list-keychains -d user | sed 's/"//g' | xargs)
security list-keychains -d user -s "$KC" ${=EXISTING}

# A successful import is not proof codesign can sign with it: check the same way build.sh
# does, so a broken search list fails here and not as a silent ad hoc build later.
identity_can_sign || {
    print -u2 "Identity imported but codesign cannot sign with it; the keychain search list may be off."
    exit 1
}
print "Created signing identity '$IDENTITY'. Future ./build.sh runs use it automatically."
