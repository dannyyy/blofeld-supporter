#!/usr/bin/env bash
#
# Builds Blofeld and assembles Blofeld.app (no Xcode project required).
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Blofeld"
BUNDLE_DIR="${APP_NAME}.app"
CONFIG="release"

# Builds with whatever toolchain is active (Command Line Tools is sufficient --
# its macOS SDK provides SwiftUI/AppKit/WebKit). To use the full Xcode toolchain
# instead, accept its license once ("sudo xcodebuild -license accept") and run:
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build-app.sh

echo "-> Building (${CONFIG})"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
RES_BUNDLE="${BIN_DIR}/${APP_NAME}_${APP_NAME}.bundle"

if [[ ! -f "$BIN_PATH" ]]; then
    echo "ERROR: built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "-> Generating app icon"
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
swift scripts/make_icon.swift "blofeld_scar_logo_v2.svg" "$ICONSET_DIR" >/dev/null
ICNS_OUT="$(mktemp -d)/AppIcon.icns"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_OUT"

echo "-> Assembling ${BUNDLE_DIR}"
rm -rf "$BUNDLE_DIR"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "$BIN_PATH" "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"
cp "Info.plist" "${BUNDLE_DIR}/Contents/Info.plist"
cp "$ICNS_OUT" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${BUNDLE_DIR}/Contents/PkgInfo"

# SwiftPM resource bundle (images) so Bundle.module resolves at runtime.
if [[ -d "$RES_BUNDLE" ]]; then
    cp -R "$RES_BUNDLE" "${BUNDLE_DIR}/Contents/Resources/"
fi

echo "-> Ad-hoc code signing"
codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null 2>&1 || \
    echo "   (codesign skipped/failed -- app will still run locally)"

echo "OK: built ${BUNDLE_DIR}"
