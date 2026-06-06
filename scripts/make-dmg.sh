#!/usr/bin/env bash
#
# Builds a styled installer DMG for Blofeld (dark "island" background, app icon +
# arrow + Applications drop target). Used both locally and by the release workflow.
#
#   ./scripts/make-dmg.sh [APP_PATH] [OUT_DMG] [VOLUME_NAME]
#
# Defaults: ./Blofeld.app -> ./Blofeld.dmg, volume "Blofeld Supporter".
# Requires Python 3 (a venv with dmgbuild is created automatically) and the Swift
# toolchain (to render the retina background).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="${1:-./Blofeld.app}"
OUT_DMG="${2:-./Blofeld.dmg}"
VOL_NAME="${3:-Blofeld Supporter}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: app not found at $APP_PATH (build it first with ./build-app.sh)" >&2
    exit 1
fi

WORK=".build/dmg"
VENV=".build/dmg-venv"
mkdir -p "$WORK"

echo "-> Ensuring dmgbuild (venv)"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip dmgbuild
fi

echo "-> Rendering background"
swift scripts/make_dmg_background.swift "$WORK/bg.png"    1 >/dev/null
swift scripts/make_dmg_background.swift "$WORK/bg@2x.png" 2 >/dev/null
# Combine into a HiDPI-aware TIFF so the background stays crisp on Retina.
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/bg.tiff" >/dev/null

echo "-> Building DMG"
rm -f "$OUT_DMG"
DMG_APP="$APP_PATH" DMG_BACKGROUND="$WORK/bg.tiff" \
    "$VENV/bin/dmgbuild" -s scripts/dmg_settings.py "$VOL_NAME" "$OUT_DMG"

echo "OK: built $OUT_DMG"
