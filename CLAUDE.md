# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Blofeld** (`Blofeld.app`, display name "Blofeld Supporter", bundle id `com.danflash.blofeld-supporter`) is a native macOS **menu-bar-only** site-reliability companion. In a dark animated "island"-style dropdown panel it surfaces two kinds of signal from two sources:

- **NServiceBus / ServiceControl** — how many error (dead-letter) messages are accumulating per endpoint (over HTTP).
- **Datadog monitors** — the monitors matched by user-configured search queries, alerting ones first (by shelling out to the local **`pup` CLI**, read-only).

It is meant to grow more reliability/DevOps integrations over time; the architecture treats each source as a parallel, **config-derived** section in the panel (a host card per ServiceControl host, a query card per Datadog query).

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

`build-app.sh` signs **ad-hoc by default**. Two optional env-var groups switch it into release mode (used by the pipeline below, but they work locally too):
- `MARKETING_VERSION` / `BUILD_VERSION` — injected into `Info.plist` (`CFBundleShortVersionString` / `CFBundleVersion`) via `PlistBuddy`. Unset → the plist's own values are kept.
- `CODESIGN_IDENTITY` (a `Developer ID Application: …` identity) switches on the **hardened runtime** (`--options runtime`) + a secure `--timestamp`, both required for notarization, and applies `CODESIGN_ENTITLEMENTS` (`Blofeld.entitlements`, which just declares `com.apple.security.network.client`) when set. No `--deep` — the only nested item is the resource-only SwiftPM bundle.

## Packaging & release

- **Styled installer DMG:** `scripts/make-dmg.sh [APP] [OUT_DMG] [VOL_NAME]` builds a dark "island"-themed installer window (app icon + arrow + Applications drop target). It auto-creates a `.build/dmg-venv` with `dmgbuild`, renders a HiDPI background by running `scripts/make_dmg_background.swift` at @1x/@2x and combining them into a HiDPI TIFF (`tiffutil -cathidpicheck`), and lays out the window via `scripts/dmg_settings.py`. **Requires Python 3 + the Swift toolchain.**
- **Fast iteration:** `scripts/preview-dmg.sh` renders a faithful mock of the installer window to a PNG and opens it (no DMG build/mount); `--dmg` also builds and opens the real DMG. Use it when tweaking `make_dmg_background.swift`.
- **CI release** (`.github/workflows/release.yml`): pushing a `v*` tag (or manual `workflow_dispatch` with a version) on `macos-15` → imports the Developer ID cert (+ the offline Apple intermediate in `.github/certs/DeveloperIDG2CA.cer`) → `build-app.sh` (Developer ID signed) → `make-dmg.sh` → sign the DMG → `notarytool submit --wait` + `stapler staple` + `spctl` gatekeeper check → publishes a GitHub Release. Needs repo secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `AC_APPLE_ID`, `AC_PASSWORD`, `AC_TEAM_ID`.

## Testing & visual verification

This environment can't click the SwiftUI `MenuBarExtra` panel (synthetic AX clicks are ignored) and `screencapture` doesn't grab hover-state cursors, so verification relies on three project-specific mechanisms:

- **Snapshot mode** — renders the panel to a PNG via `ImageRenderer` and exits. Use it to eyeball UI:
  ```bash
  BLOFELD_CONFIG_DIR=/tmp/blofeld-snap BLOFELD_SNAPSHOT=/tmp/panel.png ./Blofeld.app/Contents/MacOS/Blofeld
  ```
  `SnapshotRunner` injects sample hosts/results **and a sample Datadog query/monitors** so no backend (and no `pup`) is needed. `AppEnvironment.isSnapshot` swaps the vibrancy blur for a solid color (ImageRenderer can't draw `NSViewRepresentable`). Set `BLOFELD_SNAPSHOT_SETTINGS=1` to render `GeneralSettingsView` instead of the panel — but note `ImageRenderer` can't draw `Toggle`/`Slider`, so those come out as placeholder boxes (fine for layout checks, not for marketing screenshots).
- **Networking/logic tests** — compile the *real* source files against a mock with `swiftc`. For ServiceControl, a throwaway Python `http.server` mocks the API (URL encoding, error counting, ServicePulse-link building, SSO-wall detection). For Datadog, point **`BLOFELD_PUP_PATH`** at a tiny mock `pup` shell script that echoes canned `auth status` / `monitors search` JSON (use the **no-agent** shape: `monitors` at top level + a `counts.status` array), then:
  ```bash
  swiftc -parse-as-library Sources/Blofeld/Services/PupClient.swift \
    Sources/Blofeld/Models/Status.swift test_main.swift -o /tmp/t
  BLOFELD_PUP_PATH=/tmp/mock/pup /tmp/t   # assert state mapping, monitor URLs, total/“+N more”, availability
  ```
  This exercises `PupClient` end-to-end without touching Datadog. There is no XCTest target. (To smoke against the *real* `pup`, just leave `BLOFELD_PUP_PATH` unset — it resolves `/opt/homebrew/bin/pup`.)
- **`BLOFELD_CONFIG_DIR`** overrides the storage directory. **Always set it when testing** — otherwise you will overwrite the user's real `config.json`. `ConfigStore` keeps a one-deep `config.backup.json` and recovers from it if the main file is corrupt. `BLOFELD_PUP_PATH` overrides the `pup` binary location (tests / non-standard installs).

## Architecture

SwiftUI app; `@main BlofeldApp` declares a `MenuBarExtra(...).menuBarExtraStyle(.window)` scene (the island panel) plus a `Settings` scene. `Info.plist` sets `LSUIElement` (menu-bar-only).

**`AppState` (`@MainActor ObservableObject`) is the hub** that every view and service talks to. Key design point: the panel is **derived from config**, not stored separately —

- `config: AppConfig` (persisted) holds the user-edited hosts/endpoints, **Datadog queries**, and settings.
- `results: [String: EndpointStatus]` keyed by `AppState.key(hostId, endpoint)` holds the latest NServiceBus poll data; `monitorResults: [UUID: MonitorQueryStatus]` keyed by query id holds the latest Datadog poll data.
- The computed `hosts: [HostStatus]` and `monitorQueries: [MonitorQueryStatus]` each **merge config + results** — so editing config in Settings immediately reflects in the panel even before the next poll. `config`'s `didSet` persists, applies launch-at-login, prunes stale results, and **debounces** a poll reschedule (editing a name fires one change per keystroke).
- **`AppConfig` decodes defensively:** a hand-written `init(from:)` reads the new `datadogQueries` via `decodeIfPresent ?? []`, so configs written before Datadog support still load (a failed decode would drop the user back to `.default` and lose their hosts). Add any future field the same way.

**Data flow:** `Poller` (async loop, re-reads the interval each tick) polls **both** sources per tick:
- NServiceBus: → `ServiceControlClient` (URLSession) → `AppState.applyResults` / `applyAuth`.
- Datadog: → `PupClient` (subprocess) → `AppState.applyMonitorResults` / `setPupAvailability`.

`applyResults` diffs against the previous count to fire `NotificationService.notifyIncrease` only when an endpoint's total increases; `applyMonitorResults` diffs the previous *alerting* monitor id-set to fire `NotificationService.notifyMonitorAlert` only when a monitor **newly** enters Alert. Both log to `EventLog`. The menu-bar badge (`menuBarBadgeCount`) and `isHealthy` combine NServiceBus errors + alerting monitors.

**ServiceControl API** (`ServiceControlClient`): `GET /api/endpoints/<ep>/errors/?status=unresolved` (new = `number_of_processing_attempts == 1`, retried = `> 1`); `GET /api/recoverability/groups/Endpoint Name` resolves the group id by matching `title == endpoint`, used to build the ServicePulse deep link and the retry `POST .../groups/<id>/errors/retry`. The hosts sit behind an **OAuth2 Proxy**: a `401/403` or an HTML response means "needs auth" → `AuthManager` opens an in-app `WKWebView`, captures the `_oauth2_proxy` cookie, and copies it into `HTTPCookieStorage.shared` (shared with the client's URLSession).

**Datadog via `pup`** (`PupClient`): the app's **only subprocess** — there is no Datadog HTTP client. Each call shells out to `pup` with three pinned global flags: **`--no-agent`** (deterministic JSON: pup's *agent* mode wraps results under a `data` envelope, *no-agent* puts `monitors` at the top level — the DTOs decode the no-agent shape), **`--read-only`** (pup can never write — the app only searches and opens links), and **`--output json`**. `pup auth status` → `availability(sitesToTry:)` returns `PupAvailability.ok(site:)` / `.notInstalled` / `.notAuthenticated` / `.error`; `pup monitors search --query <Q> --per-page <N>` → `searchMonitors()` maps monitors (`status` → `MonitorState`, browser link `https://app.<site>/monitors/<id>`) and reads `counts.status` for the true total (so the panel's "+N more" is accurate beyond the fetched page). The `Poller` sorts alerting-first then caps to a display limit before storing. **Binary resolution:** a LaunchServices-launched `.app` has a minimal PATH and doesn't read `~/.zshrc`, so `PupClient.resolvePath()` checks `BLOFELD_PUP_PATH` (test override) then `/opt/homebrew/bin/pup`, `/usr/local/bin/pup`, `/usr/bin/pup`. (Process execution is allowed: the app is **not** sandboxed — entitlements only declare `network.client`.)

**`DD_SITE` is load-bearing and NOT inherited.** A Finder/LaunchServices-launched app gets the launchd environment, which has **no `DD_SITE`** (confirmed: `launchctl getenv DD_SITE` is empty). `pup` stores OAuth credentials **per site** in `~/.cache/pup/sessions.json`; with no `DD_SITE` it defaults to `datadoghq.com` and reports *not authenticated* even though the user logged into `datadoghq.eu` — and re-running `pup auth login` never fixes it because the app checks a different site. So the app **sets `DD_SITE` itself** on every `pup` invocation (`run(site:)`). The site is `config.datadogSite` when the user picked one (Settings ▸ General ▸ Datadog CLI), else **auto-detected** by `availability(sitesToTry:)` probing `DatadogSite.known` and returning the first authenticated site. `AppState.pupSitesToProbe()` orders the list — last-authenticated site first (1 call in steady state), then the rest — so detection is cheap once resolved. Do **not** assume pup picks up the right site on its own.

**Storage** all goes through `AppPaths` (honors `BLOFELD_CONFIG_DIR`): `config.json` + backup (`ConfigStore`) and `blofeld.log` (`EventLog`, which also feeds the in-panel Activity popover).

`Views/` holds the panel (`IslandPanelView`, `EndpointRowView`, `MonitorRowView`/`MonitorQuerySection`), `SettingsView` (the `.datadog` sidebar entry → `DatadogSettingsView` query editor + the General ▸ **Datadog CLI (pup)** diagnostics card), and design tokens (`Theme`). `AppAssets` renders the menu-bar icon from the **vector SVG** (not the PNG) so it stays crisp as an auto-inverting template image. It resolves the SwiftPM resource bundle from `Bundle.main.resourceURL` (where `build-app.sh` copies it, into `Contents/Resources/`), **not** via `Bundle.module` — the generated `Bundle.module` accessor looks at the `.app` root and `fatalError`s when the bundle isn't there. Keep `build-app.sh`'s copy step and `AppAssets`'s lookup in sync.

## MenuBarExtra(.window) gotchas — do not reintroduce

These caused real bugs; the constraints are load-bearing:

- **No continuously-running animations** in the panel (`repeatForever`, `ProgressView` spinners). They make the window flicker open/closed infinitely. Use static indicators (see `StatusDot`, the refresh/retry buttons).
- **No bare `ScrollView`** for the host list. A `ScrollView` with only a `maxHeight` collapses to ~0 height inside the menu-bar window and the body goes blank — render the content directly so the panel sizes to it.
- **Settings uses `HSplitView`, not `NavigationSplitView`** — the latter's title-bar-integrated sidebar toggle overlaps the window's traffic-light controls.
- The panel forces the arrow cursor via `.onContinuousHover` because SwiftUI text content otherwise shows an I-beam over the whole (non-editable) panel.
- Editing hosts uses **id-based bindings** (resolve `HostConfig`/`EndpointConfig` by `id`), never array-index bindings — index bindings crash when the array shrinks. The Datadog query editor follows the same rule via `ForEach($state.config.datadogQueries)` (Identifiable element bindings) + remove-by-id.
- Monitor rows use the same **static** `StatusDot` (no `repeatForever`); broad Datadog queries are bounded by the per-query display cap (sorted alerting-first in the `Poller` so alerts are never the ones dropped), keeping the panel height finite without a `ScrollView`.
