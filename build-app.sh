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

# Optional version injection (the release pipeline derives these from the git tag /
# run number; local builds leave them unset so Info.plist's values are kept).
PLIST="${BUNDLE_DIR}/Contents/Info.plist"
if [[ -n "${MARKETING_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" "$PLIST"
fi
if [[ -n "${BUILD_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_VERSION}" "$PLIST"
fi

# SwiftPM resource bundle (images) so Bundle.module resolves at runtime.
if [[ -d "$RES_BUNDLE" ]]; then
    cp -R "$RES_BUNDLE" "${BUNDLE_DIR}/Contents/Resources/"
fi

# Signing. Default is ad-hoc (local builds, unchanged). The release pipeline sets
# CODESIGN_IDENTITY to the real "Developer ID Application: ..." identity, which switches
# on the hardened runtime (--options runtime) + a secure timestamp -- both required for
# notarization -- and applies CODESIGN_ENTITLEMENTS when provided.
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "-> Ad-hoc code signing"
    codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null 2>&1 || \
        echo "   (codesign skipped/failed -- app will still run locally)"
else
    echo "-> Code signing with Developer ID (hardened runtime)"
    SIGN_ARGS=(--force --options runtime --timestamp)
    if [[ -n "${CODESIGN_ENTITLEMENTS:-}" ]]; then
        SIGN_ARGS+=(--entitlements "$CODESIGN_ENTITLEMENTS")
    fi
    # No --deep: the only nested item is the resource-only SwiftPM bundle (no Mach-O),
    # so signing the app bundle directly is correct.
    codesign "${SIGN_ARGS[@]}" --sign "$SIGN_IDENTITY" "$BUNDLE_DIR"
    codesign --verify --strict --verbose=2 "$BUNDLE_DIR"
fi

echo "OK: built ${BUNDLE_DIR}"
