# DSH Studio

**English** | [中文](README.md)

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Brand/AppIcon-dark.png">
    <img src="Brand/AppIcon-light.png" alt="DSH Studio project mark" width="180">
  </picture>
</p>

<p align="center">
  An unofficial third-party macOS client for DeepSeek Harness.
</p>

DSH Studio is a Swift native shell for the DeepSeek Harness Web UI: it owns the macOS window and
application lifecycle, starts and displays a local Harness Runtime inside `WKWebView`, and adds the
macOS integration Harness itself does not provide.

DSH Studio is **not** an official DeepSeek product. It is not affiliated with, authorized by,
sponsored by, or endorsed by DeepSeek.

**Normative terms**: "must" means the pipeline or the code fails when it is violated, "may not" means
the corresponding operation is rejected, and "should" is a convention that needs a reason to depart
from.

## Contents

- [1. Scope](#1-scope)
- [2. Features](#2-features)
- [3. Requirements](#3-requirements)
- [4. Build, Run, Test](#4-build-run-test)
- [5. Architecture And Layout](#5-architecture-and-layout)
- [6. Runtime: Source, Identity, Trust](#6-runtime-source-identity-trust)
- [7. Settings](#7-settings)
- [8. Plugin Market](#8-plugin-market)
- [9. Agent Preset Transfer](#9-agent-preset-transfer)
- [10. Security And Privacy Boundaries](#10-security-and-privacy-boundaries)
- [11. Local Paths](#11-local-paths)
- [12. Known Limitations](#12-known-limitations)
- [13. Licensing And Notices](#13-licensing-and-notices)

## 1. Scope

- This repository provides **the macOS shell only**: window and lifecycle, WebKit integration,
  discovery/signature-check/download/verification/installation/health-check/rollback of the local
  Runtime, the mounted settings page, and macOS-specific usability work.
- This repository does **not** implement Harness and does not fork it: the upstream Harness Web UI
  and its command behavior remain the source of truth.
- Harness and its complete dependency tree are packaged into an immutable artifact and published with
  a signed catalog by the separate
  [DSH Studio Runtime](https://github.com/SteveTanSaMa/DSH-Studio-Runtime) repository; the contract
  between the two halves lives in that repository's `docs/runtime-contract.md` (Chinese).
- This repository ships **no service**: no accounts, no API relay, no telemetry or advertising, and no
  upload of user API keys.

## 2. Features

- **Native shell**: macOS window, lifecycle, menus, keyboard handling, and WebKit integration.
- **Runtime management**: automatic first-launch installation; version checks, verified updates, and
  rollback to the previous usable installation; process-tree shutdown on quit.
- **Merged settings**: app settings are a first-party **Harness settings section** inside the Harness
  settings dialog instead of a second native preferences window.
- **Plugin market**: installs and manages the upstream `dshmarket` against the pin the Runtime
  publishes.
- **Agent Preset transfer**: import and export user-authored Presets between local installations as
  `.dshpreset` archives.
- **macOS integration**: workspace admission, system notifications, session log ZIP export, a local
  Runtime terminal, diagnostics copy and export, and front-end layout adjustments that never replace
  upstream behavior.

The Web UI is always the locally running Harness, never a remote site:

```text
DSH Studio.app
    │
    ├── Swift / macOS native shell
    │       │
    │       └── WKWebView
    │               │
    │               └── http://127.0.0.1:<port>
    │                       │
    │                       └── DeepSeek Harness Web UI
    │                               │
    │                               └── User-configured DeepSeek API
```

## 3. Requirements

- macOS 15 or later (`LSMinimumSystemVersion` = 15.0).
- Apple Silicon or Intel Mac; the architecture must match the Runtime artifact that is installed.
- Xcode with a macOS 15 SDK to build from source.
- Network access on first launch, and whenever a Runtime update is checked or installed.
- A DeepSeek API configuration supplied by the user through Harness.

**Node.js, Harness, and pnpm do not need to be installed on the host Mac**: the Runtime artifact
provides their versions and their integrity.

## 4. Build, Run, Test

```bash
git clone https://github.com/SteveTanSaMa/DSH-Studio.git
cd DSH-Studio
open "DSH Studio.xcodeproj"        # select the DSH Studio scheme and run
```

A distribution build **must** provide the signed catalog public key, otherwise remote Runtime
discovery is disabled:

```bash
RUNTIME_CATALOG_PUBLIC_KEY=base64-ed25519-public-key ./Scripts/build-app.sh
```

The key is written into `Info.plist` as `RuntimeCatalogPublicKey`. Without it the app still launches
against an installed Runtime, but it installs no new Runtime.

Tests and gates:

```bash
xcodebuild -project "DSH Studio.xcodeproj" -scheme "DSH Studio" \
  -destination "platform=macOS,arch=arm64" test     # 269 cases

python3 Scripts/check-doc-comments.py               # every in-scope declaration is documented
python3 Scripts/check-web-bridge-script.py          # the assembled injected script parses

cd Plugins/dsh-studio-settings && npm ci && npm test && npm run build
```

CI (`.github/workflows/ci.yml`) runs four jobs: the static gates; the settings plugin's tests plus
"the committed `lib/client.js` matches its sources"; the full test suite; and a DocC build of all
three modules that must produce no warnings.

The app icon is derived from the artwork in `Brand/`. After replacing either source:

```bash
Scripts/generate-app-icon.sh
```

## 5. Architecture And Layout

| Directory | Contents |
| --- | --- |
| `DSH Studio/Sources/App` | App target: lifecycle, AppModel, settings bridge, WebView host, appearance and brand, diagnostics |
| `DSH Studio/Sources/Harness` | `DeepSeekHarness` module: injected layout/behavior scripts, Harness loopback RPC client, URL policy |
| `DSH Studio/Sources/Runtime` | `DeepSeekRuntime` module: catalog verification, installation and updates, process lifecycle, profiles, plugin market |
| `DSH Studio/Sources/Logging` | `DeepSeekLogging` module: logging and redaction |
| `Plugins/dsh-studio-settings` | The first-party Harness plugin: the Host half registers the `dsh-studio` settings namespace, the browser half registers the settings page |
| `Tests/HarnessRuntimeTests` | All unit tests, including settings-page contract, process lifecycle, and real child-process cases |
| `Scripts/` | Build script, static gates, icon derivation |
| `Brand/` | Project mark sources (light and dark) |

## 6. Runtime: Source, Identity, Trust

**Installation** lives in versioned directories under the user's Application Support:

```text
~/Library/Application Support/DSH Studio/Runtimes/<runtime-version>
~/Library/Application Support/DSH Studio/Runtime              # legacy install (migration only)
```

**Version identity**: a Runtime's public version **is** the Harness version it contains, with no build
counter. Repacking the same Harness version produces no new version; the release assets and the
catalog `sha256` change instead. An artifact's identity therefore rests on the signed catalog's
SHA-256, not on the version string.

**Trust chain**: the catalog is signed JSON at a fixed address (Ed25519; `keyID` must be
`runtime-catalog-v1`, `schemaVersion` must be 1). After parsing, the release for this Mac's
architecture is selected and its dependency pins, data format, and artifact description are checked;
the download is verified byte for byte against the SHA-256; and the extracted layout and
`manifest.json` (`schemaVersion: 3`) must match the catalog entry. Any failure fails closed, and
rollback is entirely offline.

Current development snapshot (the fallback used when no signed catalog is available; what is actually
installed is what the catalog advertises):

| Component | Version | Source |
| --- | --- | --- |
| Node.js | `24.19.0` | `nodejs.org` |
| DeepSeek Harness | `@deepseek-ai/dsh@0.2.0-rc.2` | `registry.npmjs.org` |
| pnpm | `11.22.0` | `registry.npmjs.org` |
| Plugin market | `dshmarket@1.66.6` | `registry.npmjs.org` |

**Data compatibility** is fail-closed: a new Runtime reuses existing data only when the manifest and
the catalog both prove compatibility. An incompatible `dataFormat.id` (currently `sqlite-v2`) gets an
isolated data profile instead, and the previous data is never migrated, overwritten, or deleted. A
release that declares no `dataFormat` **may not** be applied as an update.

**Installation integrity** is never decided by "the directory exists": an installation is usable only
when `manifest.json` parses and matches the signed catalog's record. Installations are assembled in a
staging directory and published afterwards, so an interrupted or unverified install is never treated
as a usable Runtime.

**Process lifecycle**: a running Harness may fork a copy of itself, and such a child is reparented to
launchd when its parent receives `SIGTERM`. On quit DSH Studio therefore records and stops the
descendants observed during that launch before stopping Harness itself, and sends `SIGKILL` to
whatever is still alive after a ten-second grace period. That grace period matches the budget the
Runtime publication pipeline verifies, so a Harness still flushing session persistence is never cut
short.

## 7. Settings

DSH Studio has no separate preferences window. Its settings are one section inside the Harness
settings dialog, which stays the single place a user configures the app:

- `Plugins/dsh-studio-settings` is a Harness plugin: its Host half registers the `dsh-studio` settings
  namespace, and its browser half registers the **DSH Studio** page into Harness's own
  `settings.section` slot.
- The page is built only from the shared Harness UI primitives and design tokens, so it reads as a
  first-party page and follows the Harness theme in light and dark mode.
- **Harness owns persistence**: every write goes through Harness's settings service and is fenced by
  the namespace revision.
- Values that must be known before Harness starts — the workspace path, the conversation content
  width, and the three notification toggles — remain app-owned. The page mirrors each change back to
  the app, and the app writes its own values into the namespace once the Runtime is ready, so the two
  sides cannot drift apart.
- **Settings…** in the app menu (⌘,) opens that same Harness dialog.
- Operations the page cannot perform itself — native panels, the Runtime terminal, process control,
  diagnostics — travel over a validated `WKScriptMessageHandler` bridge and are answered on the same
  request id.

The application menu keeps the operations that must exist before or without the Harness page: Runtime
updates, the Runtime terminal, workspace selection, the data folder, the sidebar toggle, reload, Web
Inspector, logs, and diagnostics.

## 8. Plugin Market

DSH Studio can install and manage the upstream `dshmarket` plugin. The market itself manages community
plugins; this app only installs, enables, repairs, and removes that one package inside the `web`
profile, using the Runtime's bundled Node.js and pnpm paths and never a separate host installation.

**Which market version is right is not a property of the app.** It is decided by the Harness version
the Runtime contains, so the pairing travels with the Runtime release:

- A signed catalog release may carry a `pluginMarket` pin
  (`{package, version, integrity, harnessRange}`), and the artifact manifest records the same pin so
  an installation describes its own market while offline.
- The app installs and validates against that pin; its own constants are only the fallback for a
  Runtime published before the pin field existed.
- Compatibility is decided by the Harness range the market itself declares in its `peerDependencies`.
  A market outside that range is reported as incompatible, naming the range and the running Harness,
  instead of being installed and failing inside the UI.
- Prereleases are judged by the line they belong to: a `^0.1.1-rc.2` range covers 0.1.x, while a
  comparator naming the exact build still rejects an older build of that same line.

The market package is resolved from the official `registry.npmjs.org`, and its metadata and lockfile
integrity are checked before the `web` profile is changed. Third-party plugins run with the Runtime's
permissions and are **not sandboxed**, so only trusted plugins should be installed. Only the `web`
profile is managed today.

## 9. Agent Preset Transfer

User-authored Agent Presets move between local installations as `.dshpreset` archives. DSH Studio
reads and writes only `DSH_HOME/.agent-presets/<preset-id>`; built-in Presets are never exported. An
archive holds a versioned `manifest.json` and a `preset/` tree whose required entry point is
`agent.cordis.yml`.

Import is previewed first: source Harness version, file count, uncompressed size, possible credential
markers, and whether the ID collides with an existing Preset. A collision requires the user to choose
another ID, and an existing Preset is never overwritten. Installation moves the validated tree into
place as one local operation.

The transfer boundary **excludes** API keys and other credentials, Sessions, workspace files, and all
other DSH_HOME data. Archives are limited to 16 MiB compressed, 32 MiB uncompressed, 256 files, and
12 MiB per file; absolute, traversal, unsupported, duplicate, and symbolic-link entries are rejected.
Importing a Preset still grants its composition the Runtime's normal plugin and tool permissions, so
only trusted archives should be installed.

## 10. Security And Privacy Boundaries

- Harness must bind `127.0.0.1`; binding `0.0.0.0` is not allowed.
- The WebView's main page is restricted to the local loopback URL.
- Runtime and market package metadata are checked against the official registry host and pinned
  integrity values on the publishing side.
- Runtime artifacts and the signed catalog are downloaded only from the fixed Runtime GitHub Release
  addresses.
- The app never executes npm or pnpm installations, and never runs remote install scripts.
- The Runtime Builder uses `npm ci --ignore-scripts` and validates the resulting native dependencies
  before publication.
- No telemetry, analytics, advertising, or remote service endpoint is added; the child process is
  launched with telemetry disabled.
- Diagnostics are redacted before they reach the local log; API keys and bearer tokens must not appear
  in logs or issue reports.

## 11. Local Paths

```text
~/Library/Application Support/DSH Studio/DSH_HOME          # Harness data (backup-able)
~/Library/Application Support/DSH Studio/Workspace         # default workspace
~/Library/Application Support/DSH Studio/Runtimes/<ver>    # installed Runtimes
~/Library/Application Support/DSH Studio/DataProfiles/<id> # isolated data profiles
~/Library/Application Support/DSH Studio/Logs              # app and Runtime logs
```

Harness composition profiles live under `DSH_HOME/profiles`, while their active/pending/last-known-good
selection is recorded in Application Support. The workspace is selectable in settings, subject to local
directory admission checks.

## 12. Known Limitations

- This is an unofficial third-party client; upstream Harness remains the source of truth for Harness
  behavior.
- A first installation downloads roughly 188 MiB (197 MB) of Runtime artifact; how long that takes
  depends on the network.
- Third-party plugins are not sandboxed; their power equals Harness's own permissions.
- Only the `web` profile is managed today.
- A macOS appiconset **cannot** carry a dark appearance, so Finder and Launchpad keep showing the
  light icon while the running app (Dock, app switcher, About panel) switches between the light and
  dark marks with the system appearance. A fully system-level dark icon would need the macOS 26 Icon
  Composer format.
- "Which build is installed" is currently decided by version plus architecture plus every dependency
  pin. If the publisher repacks the same version without changing a dependency pin — only the
  artifact's bytes differ — that installation reads as the same build and no update is offered.

## 13. Licensing And Notices

Original DSH Studio source code is licensed under the MIT License. See [LICENSE](LICENSE).

The project mark and the derived app icon artwork are separate works and are **not** covered by the
MIT License. They are released under CC BY-NC-SA 4.0 with the attribution and permission information
described in [NOTICE](NOTICE). The sources live in `Brand/`.

DeepSeek Harness and all npm dependencies remain separate works under their own licenses; their
notices and terms must be preserved when distributing a provisioned Runtime. See [NOTICE](NOTICE) and
the package metadata inside each provisioned Runtime.

Artwork license: [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)

DSH Studio is an unofficial third-party project. DeepSeek, DeepSeek Harness, and related names and
marks belong to their respective owners. Nothing in this repository or application is an official
affiliation, authorization, sponsorship, or endorsement by DeepSeek.
