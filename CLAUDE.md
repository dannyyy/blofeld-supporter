# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Blofeld** (`Blofeld.app`, display name "Blofeld Supporter", bundle id `com.danflash.blofeld-supporter`) is a native macOS **menu-bar-only** app that polls NServiceBus / ServiceControl endpoints and surfaces how many error (dead-letter) messages are accumulating per endpoint, in a dark animated "island"-style dropdown panel.

## Build & run

There is **no Xcode project** — it builds with Swift Package Manager and a bundling script.

```bash
swift build -c release          # compile (uses the active toolchain)
./build-app.sh                  # build + generate AppIcon.icns + assemble & ad-hoc sign Blofeld.app
open ./Blofeld.app              # launch (menu-bar app, no Dock icon)
```

- **Toolchain:** the active toolchain is Command Line Tools (`xcode-select -p` → `/Library/Developer/CommandLineTools`). Its macOS SDK has SwiftUI/AppKit/WebKit, so `swift build` works **without** Xcode. Full Xcode is installed but its **license is not accepted** (`xcodebuild` fails); to use it run `sudo xcodebuild -license accept` then `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build-app.sh`.
- `build-app.sh` is plain ASCII on purpose — macOS `/bin/bash` 3.2 mis-parses UTF‑8 next to `$variables`.
- Always relaunch with `open ./Blofeld.app` (not the inner binary directly) — the SwiftUI `Settings` scene and the `MenuBarExtra` only behave correctly under a proper LaunchServices launch.

## Testing & visual verification

This environment can't click the SwiftUI `MenuBarExtra` panel (synthetic AX clicks are ignored) and `screencapture` doesn't grab hover-state cursors, so verification relies on three project-specific mechanisms:

- **Snapshot mode** — renders the panel to a PNG via `ImageRenderer` and exits. Use it to eyeball UI:
  ```bash
  BLOFELD_CONFIG_DIR=/tmp/blofeld-snap BLOFELD_SNAPSHOT=/tmp/panel.png ./Blofeld.app/Contents/MacOS/Blofeld
  ```
  `SnapshotRunner` injects sample hosts/results so no backend is needed. `AppEnvironment.isSnapshot` swaps the vibrancy blur for a solid color (ImageRenderer can't draw `NSViewRepresentable`).
- **Networking/logic tests** — compile the *real* source files against a mock server with `swiftc`, e.g.:
  ```bash
  swiftc -parse-as-library Sources/Blofeld/Models/ApiModels.swift \
    Sources/Blofeld/Services/ServiceControlClient.swift test_main.swift -o /tmp/t && /tmp/t
  ```
  A throwaway Python `http.server` is used to mock the ServiceControl API and assert URL encoding, error counting, ServicePulse-link building, and SSO-wall detection. There is no XCTest target.
- **`BLOFELD_CONFIG_DIR`** overrides the storage directory. **Always set it when testing** — otherwise you will overwrite the user's real `config.json`. `ConfigStore` keeps a one-deep `config.backup.json` and recovers from it if the main file is corrupt.

## Architecture

SwiftUI app; `@main BlofeldApp` declares a `MenuBarExtra(...).menuBarExtraStyle(.window)` scene (the island panel) plus a `Settings` scene. `Info.plist` sets `LSUIElement` (menu-bar-only).

**`AppState` (`@MainActor ObservableObject`) is the hub** that every view and service talks to. Key design point: the panel is **derived from config**, not stored separately —

- `config: AppConfig` (persisted) holds the user-edited hosts/endpoints/settings.
- `results: [String: EndpointStatus]` keyed by `AppState.key(hostId, endpoint)` holds the latest poll data.
- The computed `hosts: [HostStatus]` **merges config + results** — so editing config in Settings immediately reflects in the panel even before the next poll. `config`'s `didSet` persists, applies launch-at-login, and **debounces** a poll reschedule (editing a host name fires one change per keystroke).

**Data flow:** `Poller` (async loop, re-reads the interval each tick) → `ServiceControlClient` (URLSession) → writes back via `AppState.applyResults` / `applyAuth`. `applyResults` also diffs against the previous count to fire `NotificationService` only when an endpoint's total increases, and logs to `EventLog`.

**ServiceControl API** (`ServiceControlClient`): `GET /api/endpoints/<ep>/errors/?status=unresolved` (new = `number_of_processing_attempts == 1`, retried = `> 1`); `GET /api/recoverability/groups/Endpoint Name` resolves the group id by matching `title == endpoint`, used to build the ServicePulse deep link and the retry `POST .../groups/<id>/errors/retry`. The hosts sit behind an **OAuth2 Proxy**: a `401/403` or an HTML response means "needs auth" → `AuthManager` opens an in-app `WKWebView`, captures the `_oauth2_proxy` cookie, and copies it into `HTTPCookieStorage.shared` (shared with the client's URLSession).

**Storage** all goes through `AppPaths` (honors `BLOFELD_CONFIG_DIR`): `config.json` + backup (`ConfigStore`) and `blofeld.log` (`EventLog`, which also feeds the in-panel Activity popover).

`Views/` holds the panel (`IslandPanelView`, `EndpointRowView`), `SettingsView`, and design tokens (`Theme`). `AppAssets` renders the menu-bar icon from the **vector SVG** (not the PNG) so it stays crisp as an auto-inverting template image.

## MenuBarExtra(.window) gotchas — do not reintroduce

These caused real bugs; the constraints are load-bearing:

- **No continuously-running animations** in the panel (`repeatForever`, `ProgressView` spinners). They make the window flicker open/closed infinitely. Use static indicators (see `StatusDot`, the refresh/retry buttons).
- **No bare `ScrollView`** for the host list. A `ScrollView` with only a `maxHeight` collapses to ~0 height inside the menu-bar window and the body goes blank — render the content directly so the panel sizes to it.
- **Settings uses `HSplitView`, not `NavigationSplitView`** — the latter's title-bar-integrated sidebar toggle overlaps the window's traffic-light controls.
- The panel forces the arrow cursor via `.onContinuousHover` because SwiftUI text content otherwise shows an I-beam over the whole (non-editable) panel.
- Editing hosts uses **id-based bindings** (resolve `HostConfig`/`EndpointConfig` by `id`), never array-index bindings — index bindings crash when the array shrinks.
