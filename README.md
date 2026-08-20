# DSH Studio

<p align="center">
  <img src="鲸鱼娘.png" alt="DSH Studio project mark" width="180">
</p>

<p align="center">
  An unofficial third-party macOS client for DeepSeek Harness.
</p>

DSH Studio is a Swift-based macOS native shell for the DeepSeek Harness Web UI. It manages the macOS window and application lifecycle, starts a local Harness Runtime, and displays the Harness interface in `WKWebView`.

DSH Studio is **not** an official DeepSeek macOS client or DeepSeek product. It is not affiliated with, authorized by, sponsored by, or endorsed by DeepSeek.

## What It Does

The application keeps the upstream Harness Web UI as the main product surface and adds macOS integration around it:

- Native macOS window, lifecycle, menu, keyboard, and WebKit integration.
- Local Harness Runtime management with first-launch setup.
- Loopback-only Web UI access at `http://127.0.0.1:<port>`.
- Runtime version checks, verified updates, and rollback to the previous installation.
- Native Session log ZIP export with a save-location dialog.
- macOS-oriented settings for the workspace, Harness data directory, logs, and Runtime maintenance.
- Web UI layout and interaction adjustments that do not replace the upstream Harness application.

The architecture is:

```text
DSH Studio.app
    |
    +-- Swift / macOS native shell
            |
            +-- WKWebView
                    |
                    +-- http://127.0.0.1:<port>
                            |
                            +-- DeepSeek Harness Web UI
                                    |
                                    +-- User-configured DeepSeek API
```

The Web UI is the locally running DeepSeek Harness application. DSH Studio does not load or embed `DeepSeek.com` as its main interface, and it is not a website wrapper, scraper, or web-session client.

## Requirements

- macOS 15 or later.
- Apple Silicon or Intel Mac supported by the selected Node.js Runtime archive.
- Xcode with a macOS 15 SDK for building from source.
- Network access on the first launch, and whenever the verified Runtime is updated.
- A DeepSeek API configuration supplied by the user through DeepSeek Harness.

Node.js, Harness, and pnpm do not need to be installed separately on the host Mac.

## Build And Run

Clone the repository and open the Xcode project:

```bash
git clone https://github.com/SteveTanSaMa/DSH-Studio.git
cd DSH-Studio
open "DSH Studio.xcodeproj"
```

In Xcode, select the `DSH Studio` scheme and run the macOS application. A
distribution build must bundle `RuntimeManifest/runtime-release.json`; the
first launch then downloads the matching immutable Runtime artifact before
showing the Harness Web UI. Debug builds without a catalog retain the pinned
npm setup path only for local development.

Run the test suite from the repository root with:

```bash
xcodebuild \
  -project "DSH Studio.xcodeproj" \
  -scheme "DSH Studio" \
  -destination "platform=macOS,arch=arm64" \
  test
```

For an Intel build, use the appropriate `x86_64` destination available on the development Mac.

## Runtime Setup

The verified Runtime artifact is downloaded on demand into the user's
Application Support directory:

```text
~/Library/Application Support/DSH Studio/Runtime
```

The app does not resolve npm `latest` or run npm on the user's Mac. The Runtime
Builder resolves the latest published Harness and pnpm versions, creates a
complete dependency snapshot, runs smoke tests, and publishes an immutable
artifact. The app receives only the resulting release catalog and artifact.

The current development snapshot contains:

| Component | Version | Source |
| --- | --- | --- |
| Node.js | `24.19.0` | `nodejs.org` |
| DeepSeek Harness | `@deepseek-ai/dsh@0.1.0-rc.6` | `registry.npmjs.org` |
| pnpm | `11.7.0` | `registry.npmjs.org` |

The Runtime Builder process is intentionally explicit:

1. `Scripts/build-runtime.sh` resolves `@deepseek-ai/dsh@latest` and `pnpm@latest` from `registry.npmjs.org`.
2. It downloads a fixed Node.js version, creates a lockfile, and runs `npm ci --ignore-scripts` in the isolated build directory.
3. Harness, pnpm, native dependencies, and the local `host.describe` smoke test are validated.
4. The script emits an architecture-specific tarball, manifest, SHA-256 file, and artifact metadata.
5. `Scripts/generate-runtime-catalog.sh` combines the arm64 and x86_64 metadata into the catalog bundled by the app.

The user-facing installation process is separate:

1. DSH Studio downloads the catalog-selected GitHub Release artifact over HTTPS and verifies its SHA-256 checksum.
2. It validates the tar listing, extracts into a staging directory, and checks the Runtime manifest and executable versions.
3. Harness and the Runtime-owned pnpm package are validated before the Runtime is published.
4. Harness processes receive the Runtime's Node and pnpm paths before inherited user paths.

The Harness plugin and profile commands invoke `pnpm` by name. DSH Studio therefore uses the pnpm shim installed inside the Runtime and does not depend on Homebrew, Corepack, or another application's pnpm installation.

The Runtime is published only after its executable, package versions, native dependencies, checksums, and manifest have been verified. An interrupted or incomplete installation is not treated as usable. The previous complete installation is retained as a single rollback copy.

## Runtime Updates And Rollback

The installed Runtime can be inspected and maintained from the Runtime section of the application settings:

- **Check** compares the installed manifest with the catalog release bundled by the app.
- **Update** stops the local Harness process, downloads and stages the catalog-selected verified Runtime, and keeps the previous installation as a rollback copy.
- **Rollback** restores the previous verified installation.
- If an updated Runtime cannot start or become healthy, DSH Studio automatically stops it and attempts to restore the previous installation.

Runtime Builder inputs may follow npm `latest`, but each published artifact is pinned by its generated manifest and SHA-256. User installs and updates always use that immutable snapshot, which keeps checksum verification and rollback meaningful.

## API Keys And Privacy

DSH Studio does not provide a DeepSeek API key, proxy API requests, sell API access, or upload user API keys to a DSH Studio server. Users configure their own API access through the local Harness application.

DSH Studio does not add telemetry or analytics. The local Runtime is launched with telemetry disabled, and application diagnostics are redacted before being written to the local log. API keys and bearer tokens must not be placed in issue reports or debug output.

The default Harness data and workspace locations are under:

```text
~/Library/Application Support/DSH Studio/DSH_HOME
~/Library/Application Support/DSH Studio/Workspace
```

These locations can be changed in the application settings. DSH Studio does not upload those directories as part of its Runtime management.

## Localhost And Security Boundaries

- Harness is explicitly started on `127.0.0.1`, not `0.0.0.0`.
- The WebView's main Harness page is restricted to the local loopback URL.
- Runtime package metadata is checked against the official npm registry host and pinned package integrity values during the Builder step.
- Runtime artifacts are downloaded from the fixed DSH Studio GitHub Release URL in the bundled catalog.
- The user-facing app does not execute npm, pnpm installation, or remote installation scripts.
- Runtime Builder uses `npm ci --ignore-scripts` and validates the resulting native dependencies before publication.
- The native shell does not add a remote service, API relay, advertisement, or user-behavior analytics endpoint.

## Project Status

DSH Studio is an open-source development project. The upstream DeepSeek Harness Web UI and its command behavior remain the source of truth for Harness functionality. DSH Studio focuses on the macOS shell, local process lifecycle, WebKit integration, Runtime provisioning, and macOS-specific usability.

Upstream Harness changes are adopted by building a new Runtime artifact, passing the smoke tests, generating a new catalog, and packaging that catalog with the next DSH Studio build.

## Licensing

Original DSH Studio source code is licensed under the MIT License. See [LICENSE](LICENSE).

The project mark and derived app icon artwork are separate artwork and are **not** covered by the DSH Studio MIT License. They are released under CC BY-NC-SA 4.0 with the attribution and permission information described in [NOTICE](NOTICE).

DeepSeek Harness and all npm dependencies remain separate works under their own licenses. Their notices and license terms must be preserved when distributing a provisioned Runtime. See [NOTICE](NOTICE) and the relevant package metadata in [DSH Studio/RuntimeManifest/package-lock.json](DSH%20Studio/RuntimeManifest/package-lock.json).

Artwork license: [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)

## Disclaimer

DSH Studio is an unofficial third-party project. DeepSeek, DeepSeek Harness, and related names or marks belong to their respective owners. Nothing in this repository or application should be interpreted as official affiliation, authorization, sponsorship, or endorsement by DeepSeek.
