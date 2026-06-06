# Blofeld Supporter

A native macOS **menu-bar-only** app that polls [NServiceBus](https://particular.net/nservicebus) / [ServiceControl](https://docs.particular.net/servicecontrol/) endpoints and surfaces how many error (dead-letter) messages are piling up per endpoint — shown in a dark, animated "island"-style dropdown panel.

- **App name:** `Blofeld.app` (display name "Blofeld Supporter")
- **Bundle id:** `com.danflash.blofeld-supporter`
- **Platform:** macOS 14+ (`LSUIElement` — no Dock icon, lives in the menu bar)

## What it does

- Polls one or more ServiceControl endpoints on an interval and counts **unresolved error messages** per endpoint, split into _new_ (first processing attempt) and _retried_ (subsequent attempts).
- Fires a notification only when an endpoint's error count **increases**.
- Builds a [ServicePulse](https://docs.particular.net/servicepulse/) deep link for each endpoint group, and can trigger a **retry** of a group's errors right from the panel.
- Handles hosts sitting behind an **OAuth2 Proxy**: when a request comes back `401/403` or returns HTML, an in-app `WKWebView` opens for sign-in and the captured `_oauth2_proxy` cookie is reused for subsequent API calls.

## Build & run

There is **no Xcode project** — the app builds with Swift Package Manager plus a bundling script.

```bash
swift build -c release   # compile (uses the active toolchain)
./build-app.sh           # build + generate AppIcon.icns + assemble & ad-hoc sign Blofeld.app
open ./Blofeld.app       # launch (menu-bar app, no Dock icon)
```

Always relaunch with `open ./Blofeld.app` rather than running the inner binary directly — the SwiftUI `Settings` scene and `MenuBarExtra` only behave correctly under a proper LaunchServices launch.

### Toolchain notes

- The active **Command Line Tools** toolchain is sufficient: its macOS SDK provides SwiftUI/AppKit/WebKit, so `swift build` works without Xcode.
- To build with full Xcode instead, accept its license once and point the build at it:
  ```bash
  sudo xcodebuild -license accept
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build-app.sh
  ```
- `build-app.sh` is intentionally plain ASCII — macOS `/bin/bash` 3.2 mis-parses UTF‑8 adjacent to `$variables`.

## Configuration & storage

All storage goes through `AppPaths`, which honors the `BLOFELD_CONFIG_DIR` environment variable:

- `config.json` (+ a one-deep `config.backup.json`) — user-edited hosts, endpoints, and settings, managed by `ConfigStore`. It recovers from the backup if the main file is corrupt.
- `blofeld.log` — event log (`EventLog`), which also feeds the in-panel Activity popover.

> **When testing, always set `BLOFELD_CONFIG_DIR`** to a scratch directory — otherwise you will overwrite your real `config.json`.

## Architecture

A SwiftUI app whose `@main BlofeldApp` declares a `MenuBarExtra(...).menuBarExtraStyle(.window)` scene (the island panel) plus a `Settings` scene.

**`AppState` (`@MainActor ObservableObject`) is the hub** that every view and service talks to. The panel is **derived from config**, not stored separately:

- `config: AppConfig` (persisted) holds the user-edited hosts/endpoints/settings.
- `results: [String: EndpointStatus]` holds the latest poll data, keyed by `AppState.key(hostId, endpoint)`.
- The computed `hosts: [HostStatus]` **merges config + results**, so edits in Settings show up in the panel immediately, before the next poll. `config`'s `didSet` persists, applies launch-at-login, and debounces a poll reschedule.

**Data flow:** `Poller` (async loop, re-reads the interval each tick) → `ServiceControlClient` (URLSession) → writes back via `AppState.applyResults` / `applyAuth`. `applyResults` diffs against the previous count to fire `NotificationService` only on increases, and logs to `EventLog`.

### ServiceControl API

- `GET /api/endpoints/<ep>/errors/?status=unresolved` — _new_ = `number_of_processing_attempts == 1`, _retried_ = `> 1`.
- `GET /api/recoverability/groups/<Endpoint Name>` — resolves the group id by matching `title == endpoint`; used to build the ServicePulse deep link and the retry `POST .../groups/<id>/errors/retry`.

### Project layout

```
Sources/Blofeld/
  BlofeldApp.swift          @main scene declarations
  AppState.swift            central @MainActor hub (config + results -> hosts)
  AppAssets.swift           menu-bar icon rendered from the vector SVG
  SnapshotRunner.swift      sample data injection for snapshot mode
  Models/                   ApiModels, Status, Configuration
  Views/                    IslandPanelView, EndpointRowView, SettingsView,
                            Theme, Components, Toast
  Services/                 ServiceControlClient, Poller, ConfigStore, AuthManager,
                            NotificationService, LaunchAtLogin, EventLog, AppPaths
  Resources/                blofeld_scar_logo_v2.{svg,png}
```

## Testing & visual verification

There is no XCTest target. Verification relies on three project-specific mechanisms:

- **Snapshot mode** — renders the panel to a PNG via `ImageRenderer`, then exits. `SnapshotRunner` injects sample hosts/results, so no backend is needed:
  ```bash
  BLOFELD_CONFIG_DIR=/tmp/blofeld-snap BLOFELD_SNAPSHOT=/tmp/panel.png ./Blofeld.app/Contents/MacOS/Blofeld
  ```
- **Networking/logic tests** — compile the real source files against a mock server with `swiftc`:
  ```bash
  swiftc -parse-as-library Sources/Blofeld/Models/ApiModels.swift \
    Sources/Blofeld/Services/ServiceControlClient.swift test_main.swift -o /tmp/t && /tmp/t
  ```
  A throwaway Python `http.server` mocks the ServiceControl API to assert URL encoding, error counting, ServicePulse-link building, and SSO-wall detection.

## `MenuBarExtra(.window)` constraints

These constraints are load-bearing — each fixed a real bug:

- **No continuously-running animations** in the panel (`repeatForever`, `ProgressView` spinners) — they flicker the window open/closed. Use static indicators (`StatusDot`, the refresh/retry buttons).
- **No bare `ScrollView`** for the host list — with only a `maxHeight` it collapses to ~0 height and the body goes blank. Render the content directly so the panel sizes to it.
- **Settings uses `HSplitView`, not `NavigationSplitView`** — the latter's sidebar toggle overlaps the window's traffic-light controls.
- The panel forces the arrow cursor via `.onContinuousHover` (SwiftUI otherwise shows an I-beam over the non-editable panel).
- Editing hosts uses **id-based bindings** (resolve `HostConfig`/`EndpointConfig` by `id`), never array-index bindings — index bindings crash when the array shrinks.
