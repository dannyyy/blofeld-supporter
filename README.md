<div align="center">

<img src="blofeld_scar_logo_v2.png" width="120" alt="Blofeld Supporter icon" />

# Blofeld Supporter

**A site-reliability companion for your macOS menu bar — watch NServiceBus error queues and Datadog monitors at a glance.**

<img src="docs/images/panel.png" width="320" alt="The Blofeld Supporter dropdown panel showing endpoints and their error counts" />

</div>

---

## What is it?

Blofeld Supporter is a tiny macOS app that lives in your **menu bar** and quietly keeps an eye on your
services. It watches your
[NServiceBus](https://particular.net/nservicebus) / [ServiceControl](https://docs.particular.net/servicecontrol/)
endpoints **and** your [Datadog](https://www.datadoghq.com/) monitors, so you spot trouble — messages
piling up in an error (dead-letter) queue, or a monitor going red — without keeping a tab open all day.

Click the menu-bar icon and a dark, compact panel drops down showing every endpoint and monitor you
track. NServiceBus endpoints show their error counts split into **new** and **already-retried**; Datadog
monitors show their state, alerting ones first. If something is on fire, you can jump straight to
ServicePulse, retry an endpoint's error group, or open a monitor in Datadog — without leaving the panel.

It has **no Dock icon and no window clutter** — just the icon in your menu bar. More integrations for
day-to-day site reliability and DevOps are planned.

## Features

### NServiceBus / ServiceControl
- **At-a-glance error counts** per endpoint, grouped by host (e.g. _Production_, _Staging_).
- **New vs. retried** breakdown so you can tell fresh failures from ones already being reprocessed.
- **One-click retry** of an endpoint's error group, straight from the panel.
- **Jump to ServicePulse** for any endpoint to dig into the details.
- **Single sign-on aware** — if your ServiceControl sits behind an OAuth2 proxy, Blofeld opens a
  sign-in window the first time and remembers your session.

### Datadog monitors
- **Watch monitors by query** — configure one or more Datadog monitor searches (e.g.
  `team:blofeld status:alert`); every matching monitor shows in the panel with its state.
- **Alerting first** — alerting and warning monitors sort to the top; broad queries are capped with a
  "+N more" line so the panel stays readable.
- **Open in Datadog** — jump to any monitor in your browser to resolve, mute, or investigate it.
- Powered by the [`pup`](https://github.com/DataDog/pup) CLI (read-only) — your existing Datadog login.

### General
- **Desktop notifications** that fire only when something *newly* needs attention — an endpoint's error
  count rises, or a monitor enters alert — no nagging.
- **Activity log** of recent changes, viewable in the panel.
- **Configurable polling interval** and **launch-at-login**.

## Requirements

- macOS **14 (Sonoma)** or newer.
- For NServiceBus: network access to one or more **ServiceControl** instances (and their matching
  **ServicePulse** URLs).
- For Datadog: the **[`pup`](https://github.com/DataDog/pup) CLI**, installed and authenticated (see
  _Set up Datadog monitors_ below). Optional — leave it out if you only use NServiceBus.

## Install

1. Download the latest **`Blofeld-x.y.z.dmg`** from the
   [**Releases page**](https://github.com/dannyyy/blofeld-supporter/releases/latest).
2. Open the DMG and **drag `Blofeld Supporter` onto the `Applications` folder**.
3. Launch it from Applications (or Spotlight). The icon appears in your menu bar — there is no Dock icon.

> The release builds are **signed with a Developer ID and notarized by Apple**, so they open without
> Gatekeeper warnings. If you build it yourself instead, macOS may ask you to confirm the first launch.

## Set up your hosts

The first time you open Blofeld, you'll want to tell it which endpoints to watch.

1. Click the menu-bar icon, then open **Settings** (the gear).
2. Under **Monitored Hosts**, click **＋** to add a host and give it a **Display name** (e.g. _Production_).
3. Fill in the two URLs:
   - **ServiceControl API** — e.g. `https://servicecontrol.example.com`
   - **ServicePulse** — e.g. `https://servicepulse.example.com`
4. Under **Endpoints**, add the **endpoint names** you want to watch (one per row, matching the names
   shown in ServicePulse, e.g. `order-processor`).
5. Repeat for as many hosts as you like.

Your changes show up in the panel **immediately** — you don't have to wait for the next poll.

If your ServiceControl is protected by single sign-on, Blofeld opens a browser window the first time it
needs to authenticate. Sign in once and it reuses the session for subsequent checks.

## Set up Datadog monitors

Blofeld reads your Datadog monitors through the **`pup`** CLI, so it reuses your existing Datadog login
and never needs API keys of its own.

1. **Install `pup`** (one-time):
   ```bash
   brew tap datadog-labs/pack
   brew install datadog-labs/pack/pup
   ```
   If your org is on the EU site, also set the site for the CLI:
   ```bash
   echo 'export DD_SITE="datadoghq.eu"' >> ~/.zshrc
   ```
2. **Sign in:**
   ```bash
   pup auth login
   ```
3. In Blofeld, open **Settings ▸ General** and check the **Datadog CLI (pup)** box — it should show
   _Installed & authenticated_. If not, it tells you exactly what to run.
4. Open **Settings ▸ Datadog ▸ Monitors** and add one or more **queries**. Each has a friendly name and
   a monitor search query, for example:
   - `team:blofeld status:alert` — your team's alerting monitors
   - `service:checkout` — everything for a service
   - `tag:"env:prod"` — a tag scope

Every matching monitor appears in the panel (alerting ones first). Click a monitor's arrow to open it in
Datadog, where you can resolve or mute it. Blofeld only ever **reads** monitors (`pup` is run with
`--read-only`); it never changes them.

## Preferences

Open **Settings** from the panel to adjust:

- **Start at login** — launch Blofeld automatically when you log in.
- **Notifications** — get alerted when new errors appear (you may need to allow Blofeld under
  *System Settings ▸ Notifications* the first time; there's a **Send test notification** button to check).
- **Check every** — how often Blofeld polls each endpoint and Datadog query.
- **Datadog CLI (pup)** — see whether the `pup` CLI is installed and authenticated, with a hint to fix
  it if not.
- **Diagnostics** — open the log file or reveal the configuration folder in Finder.

## Your data & privacy

Blofeld talks only to the ServiceControl/ServicePulse hosts **you** configure. Everything it stores stays
on your Mac, in `~/Library/Application Support/com.danflash.blofeld-supporter/`:

- `config.json` — your hosts, endpoints and preferences (with a one-deep backup that it restores from if
  the file ever gets corrupted).
- `blofeld.log` — a local activity log, also shown in the panel's Activity view.

## Building from source

Prefer to build it yourself? The app uses Swift Package Manager plus a small bundling script — **no Xcode
project required**:

```bash
swift build -c release   # compile
./build-app.sh           # assemble & sign Blofeld.app
open ./Blofeld.app       # launch
```

For the full developer guide — architecture, the DMG/notarization release pipeline, and testing notes —
see [`CLAUDE.md`](./CLAUDE.md).
