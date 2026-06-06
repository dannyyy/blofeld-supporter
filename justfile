# Blofeld Supporter — task runner.
# Run `just` (or `just --list`) to see all recipes.

set shell := ["bash", "-uc"]

# Storage dir used by test/preview recipes so they never touch the real config.json.
test_config_dir := "/tmp/blofeld-test"

# Show the available recipes.
default:
    @just --list

# --- Local development -------------------------------------------------------

# Quick compile only (no .app bundle). Fast feedback loop.
compile:
    swift build -c release

# Build and assemble Blofeld.app (ad-hoc signed) for local use.
build:
    ./build-app.sh

# Build then launch the app via LaunchServices (required for MenuBarExtra/Settings).
run: build
    open ./Blofeld.app

# Render the island panel to a PNG and open it (no backend needed).
snapshot:
    BLOFELD_CONFIG_DIR={{test_config_dir}} BLOFELD_SNAPSHOT=/tmp/blofeld-panel.png ./Blofeld.app/Contents/MacOS/Blofeld
    open /tmp/blofeld-panel.png

# Render the Settings view to a PNG and open it (layout check only).
snapshot-settings:
    BLOFELD_CONFIG_DIR={{test_config_dir}} BLOFELD_SNAPSHOT=/tmp/blofeld-settings.png BLOFELD_SNAPSHOT_SETTINGS=1 ./Blofeld.app/Contents/MacOS/Blofeld
    open /tmp/blofeld-settings.png

# --- Packaging ---------------------------------------------------------------

# Build a styled installer DMG locally (ad-hoc signed; not notarized).
dmg: build
    ./scripts/make-dmg.sh ./Blofeld.app ./Blofeld.dmg "Blofeld Supporter"

# Fast preview of the DMG installer window as a PNG (no DMG build/mount).
preview-dmg:
    ./scripts/preview-dmg.sh

# --- Release -----------------------------------------------------------------

# Cut a GitHub release: tag the version, let CI build+sign+notarize+publish the
# DMG, wait for it to finish, then set the release body from a markdown notes file.
#   just release 0.2.0 notes.md
release version notes_file:
    #!/usr/bin/env bash
    set -euo pipefail
    version="{{version}}"
    tag="v${version#v}"
    notes="{{notes_file}}"

    [[ -f "$notes" ]] || { echo "ERROR: notes file not found: $notes" >&2; exit 1; }
    [[ -z "$(git status --porcelain)" ]] || { echo "ERROR: working tree not clean" >&2; exit 1; }
    branch="$(git rev-parse --abbrev-ref HEAD)"
    [[ "$branch" == "main" ]] || { echo "ERROR: not on main (on '$branch')" >&2; exit 1; }
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        echo "ERROR: tag $tag already exists" >&2; exit 1
    fi

    echo "-> Syncing main with origin"
    git fetch --quiet origin
    git pull --ff-only --quiet

    echo "-> Tagging $tag and pushing (triggers the Release workflow)"
    git tag -a "$tag" -m "$tag"
    git push --quiet origin "$tag"

    echo "-> Locating the Release workflow run"
    run_id=""
    for _ in $(seq 1 30); do
        run_id="$(gh run list --workflow=release.yml --branch "$tag" --limit 1 \
            --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
        [[ -n "$run_id" ]] && break
        sleep 5
    done
    [[ -n "$run_id" ]] || { echo "ERROR: no workflow run found — check GitHub Actions" >&2; exit 1; }

    echo "-> Watching run $run_id (build + notarize, this takes a few minutes)"
    gh run watch "$run_id" --exit-status

    echo "-> Setting release notes from $notes"
    gh release edit "$tag" --notes-file "$notes"
    echo "OK: released $tag"

# Replace the notes of an existing release (e.g. after CI already published it).
#   just release-notes 0.2.0 notes.md
release-notes version notes_file:
    #!/usr/bin/env bash
    set -euo pipefail
    version="{{version}}"
    tag="v${version#v}"
    [[ -f "{{notes_file}}" ]] || { echo "ERROR: notes file not found: {{notes_file}}" >&2; exit 1; }
    gh release edit "$tag" --notes-file "{{notes_file}}"
    echo "OK: updated notes for $tag"

# --- Housekeeping ------------------------------------------------------------

# Remove build artifacts.
clean:
    rm -rf .build Blofeld.app Blofeld.dmg
