#!/usr/bin/env bash
#
# Fast local preview of the DMG installer window WITHOUT building/mounting a DMG.
# Renders a faithful mock (title bar + dark background + real app/Applications
# icons + labels + arrow) to a PNG and opens it. Use this to iterate on the
# background design (scripts/make_dmg_background.swift) quickly.
#
#   ./scripts/preview-dmg.sh            # mock PNG, then open it
#   ./scripts/preview-dmg.sh --dmg      # also build the real DMG and open it
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${TMPDIR:-/tmp}/blofeld-dmg-preview.png"

if [[ ! -d Blofeld.app ]]; then
    echo "-> Building Blofeld.app (for its icon)"
    BLOFELD_CONFIG_DIR="${TMPDIR:-/tmp}/blofeld-preview" ./build-app.sh >/dev/null
fi

echo "-> Rendering preview mock"
swift scripts/make_dmg_background.swift "$OUT" 2 --preview "$PWD/Blofeld.app" >/dev/null
echo "OK: $OUT"
open "$OUT"

if [[ "${1:-}" == "--dmg" ]]; then
    echo "-> Building real DMG"
    ./scripts/make-dmg.sh ./Blofeld.app "${TMPDIR:-/tmp}/Blofeld-preview.dmg" "Blofeld Supporter"
    open "${TMPDIR:-/tmp}/Blofeld-preview.dmg"
fi
