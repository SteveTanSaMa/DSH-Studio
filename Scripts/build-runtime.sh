#!/usr/bin/env bash
set -euo pipefail

# Builds an immutable Runtime artifact for one macOS architecture.
#
# npm is deliberately used only during this build step, never by the
# installed application.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die() {
    printf 'build-runtime: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

RUNTIME_VERSION="${RUNTIME_VERSION:-${1:-}}"
ARCHITECTURE="${ARCHITECTURE:-${2:-}}"
NODE_VERSION="${NODE_VERSION:-24.19.0}"
REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPOSITORY_ROOT/RuntimeArtifacts}"
ARTIFACT_BASE_URL="${RUNTIME_ARTIFACT_BASE_URL:-https://github.com/SteveTanSaMa/DSH-Studio/releases/download/runtime-${RUNTIME_VERSION}}"

[ -n "$RUNTIME_VERSION" ] || die "usage: RUNTIME_VERSION=2026.08.20.1 ARCHITECTURE=darwin-arm64 $0"
case "$RUNTIME_VERSION" in
    *[!A-Za-z0-9._-]*) die "RUNTIME_VERSION contains unsupported characters" ;;
esac

if [ -z "$ARCHITECTURE" ]; then
    case "$(uname -m)" in
        arm64) ARCHITECTURE="darwin-arm64" ;;
        x86_64) ARCHITECTURE="darwin-x64" ;;
        *) die "unsupported host architecture: $(uname -m)" ;;
    esac
fi

case "$ARCHITECTURE" in
    darwin-arm64) NODE_SUFFIX="arm64" ;;
    darwin-x64) NODE_SUFFIX="x64" ;;
    *) die "unsupported Runtime architecture: $ARCHITECTURE" ;;
esac

require_command curl
require_command shasum
require_command tar
require_command npm

# The current Harness dependency graph can exceed Node's default ~2 GiB V8
# heap during npm install. Keep the limit configurable for smaller runners,
# while giving CI enough headroom for the official Runtime build.
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=6144}"

WORK_DIR="${WORK_DIR:-}"
REMOVE_WORK_DIR=0
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dsh-runtime-builder.XXXXXX")"
    REMOVE_WORK_DIR=1
else
    mkdir -p "$WORK_DIR"
fi

cleanup() {
    if [ "$REMOVE_WORK_DIR" -eq 1 ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

STAGE_DIR="$WORK_DIR/runtime"
NODE_ROOT="$STAGE_DIR/node/$ARCHITECTURE"
HARNESS_VERSION="${HARNESS_VERSION:-}"
PNPM_VERSION="${PNPM_VERSION:-}"
DATA_FORMAT_ID="${DSH_RUNTIME_DATA_FORMAT_ID:-}"
DATA_FORMAT_COMPATIBLE_WITH="${DSH_RUNTIME_DATA_FORMAT_COMPATIBLE_WITH:-}"
DATA_FORMAT_MIGRATION="${DSH_RUNTIME_DATA_FORMAT_MIGRATION:-}"

mkdir -p "$STAGE_DIR"

NODE_ARCHIVE_NAME="node-v${NODE_VERSION}-darwin-${NODE_SUFFIX}.tar.gz"
NODE_BASE_URL="https://nodejs.org/dist/v${NODE_VERSION}"
NODE_ARCHIVE_URL="$NODE_BASE_URL/$NODE_ARCHIVE_NAME"
NODE_CHECKSUMS="$WORK_DIR/SHASUMS256.txt"
NODE_ARCHIVE="$WORK_DIR/$NODE_ARCHIVE_NAME"

printf 'Downloading Node.js %s for %s\n' "$NODE_VERSION" "$ARCHITECTURE"
curl -fsSL --connect-timeout 20 --max-time 900 --retry 3 "$NODE_BASE_URL/SHASUMS256.txt" -o "$NODE_CHECKSUMS"
EXPECTED_NODE_SHA256="$(awk -v name="$NODE_ARCHIVE_NAME" '$2 == name { print $1; exit }' "$NODE_CHECKSUMS")"
[ -n "$EXPECTED_NODE_SHA256" ] || die "Node archive is missing from the official checksum list"
curl -fsSL --connect-timeout 20 --max-time 900 --retry 3 "$NODE_ARCHIVE_URL" -o "$NODE_ARCHIVE"
ACTUAL_NODE_SHA256="$(shasum -a 256 "$NODE_ARCHIVE" | awk '{print $1}')"
[ "$ACTUAL_NODE_SHA256" = "$EXPECTED_NODE_SHA256" ] || die "Node archive checksum mismatch"

mkdir -p "$NODE_ROOT"
tar -xzf "$NODE_ARCHIVE" -C "$NODE_ROOT" --strip-components 1

NODE_EXECUTABLE="$NODE_ROOT/bin/node"
NPM_CLI="$NODE_ROOT/lib/node_modules/npm/bin/npm-cli.js"
[ -x "$NODE_EXECUTABLE" ] || die "downloaded Node executable is missing"
[ -f "$NPM_CLI" ] || die "downloaded Node npm CLI is missing"

resolve_latest() {
    local package_name="$1"
    "$NODE_EXECUTABLE" "$NPM_CLI" view "$package_name" version \
        --registry "$REGISTRY" 2>/dev/null | tr -d '[:space:]'
}

if [ -z "$HARNESS_VERSION" ]; then
    HARNESS_VERSION="$(resolve_latest '@deepseek-ai/dsh')"
fi
if [ -z "$PNPM_VERSION" ]; then
    PNPM_VERSION="$(resolve_latest 'pnpm')"
fi
[ -n "$HARNESS_VERSION" ] || die "could not resolve @deepseek-ai/dsh@latest"
[ -n "$PNPM_VERSION" ] || die "could not resolve pnpm@latest"

case "$HARNESS_VERSION" in
    *[!A-Za-z0-9._-]*) die "resolved Harness version contains unsupported characters" ;;
esac
case "$PNPM_VERSION" in
    *[!A-Za-z0-9._-]*) die "resolved pnpm version contains unsupported characters" ;;
esac

HARNESS_ROOT="$STAGE_DIR/harness/$ARCHITECTURE/$HARNESS_VERSION"
mkdir -p "$HARNESS_ROOT"

"$NODE_EXECUTABLE" - "$HARNESS_ROOT/package.json" "$HARNESS_VERSION" "$PNPM_VERSION" <<'NODE'
const fs = require("fs");
const [path, harnessVersion, pnpmVersion] = process.argv.slice(2);
fs.writeFileSync(path, JSON.stringify({
  name: "deepseek-harness-macos-runtime",
  version: "0.0.1",
  private: true,
  dependencies: {
    "@deepseek-ai/dsh": harnessVersion,
    pnpm: pnpmVersion
  }
}, null, 2) + "\n");
NODE

printf 'Resolving Harness %s and pnpm %s\n' "$HARNESS_VERSION" "$PNPM_VERSION"
(
    cd "$HARNESS_ROOT"
    "$NODE_EXECUTABLE" "$NPM_CLI" install \
        --ignore-scripts \
        --include=optional \
        --no-audit \
        --no-fund \
        --registry "$REGISTRY"
    rm -rf node_modules
    "$NODE_EXECUTABLE" "$NPM_CLI" ci \
        --ignore-scripts \
        --include=optional \
        --no-audit \
        --no-fund \
        --registry "$REGISTRY"
)

HARNESS_ENTRY="$HARNESS_ROOT/node_modules/@deepseek-ai/dsh/lib/bin.js"
PNPM_PACKAGE="$HARNESS_ROOT/node_modules/pnpm/package.json"
PNPM_EXECUTABLE="$HARNESS_ROOT/node_modules/.bin/pnpm"
[ -f "$HARNESS_ENTRY" ] || die "Harness entry point is missing"
[ -f "$PNPM_PACKAGE" ] || die "pnpm package is missing"
[ -x "$PNPM_EXECUTABLE" ] || die "pnpm shim is missing or not executable"

NATIVE_ROOT="$HARNESS_ROOT/node_modules/node-pty/prebuilds/$ARCHITECTURE"
PTY_BINARY="$NATIVE_ROOT/pty.node"
SPAWN_HELPER="$NATIVE_ROOT/spawn-helper"
[ -f "$PTY_BINARY" ] || die "node-pty native binary is missing"
[ -f "$SPAWN_HELPER" ] || die "node-pty spawn helper is missing"
chmod 755 "$SPAWN_HELPER"

export DSH_RUNTIME_VERSION="$RUNTIME_VERSION"
export DSH_RUNTIME_ARCHITECTURE="$ARCHITECTURE"
export DSH_RUNTIME_NODE_VERSION="$NODE_VERSION"
export DSH_RUNTIME_HARNESS_VERSION="$HARNESS_VERSION"
export DSH_RUNTIME_PNPM_VERSION="$PNPM_VERSION"
export DSH_RUNTIME_NODE_SHA256="$ACTUAL_NODE_SHA256"
export DSH_RUNTIME_REGISTRY="$REGISTRY"
export DSH_RUNTIME_DATA_FORMAT_ID="$DATA_FORMAT_ID"
export DSH_RUNTIME_DATA_FORMAT_COMPATIBLE_WITH="$DATA_FORMAT_COMPATIBLE_WITH"
export DSH_RUNTIME_DATA_FORMAT_MIGRATION="$DATA_FORMAT_MIGRATION"

"$NODE_EXECUTABLE" - "$HARNESS_ROOT/package-lock.json" "$STAGE_DIR/manifest.json" <<'NODE'
const fs = require("fs");
const [lockPath, manifestPath] = process.argv.slice(2);
const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
const packages = lock.packages || {};
const root = packages[""] || {};
const dependencies = root.dependencies || {};
const harness = packages["node_modules/@deepseek-ai/dsh"];
const pnpm = packages["node_modules/pnpm"];
const expectedHarness = process.env.DSH_RUNTIME_HARNESS_VERSION;
const expectedPnpm = process.env.DSH_RUNTIME_PNPM_VERSION;
const dataFormatID = process.env.DSH_RUNTIME_DATA_FORMAT_ID;
const compatibleWith = (process.env.DSH_RUNTIME_DATA_FORMAT_COMPATIBLE_WITH || "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
if (lock.lockfileVersion !== 3 ||
    dependencies["@deepseek-ai/dsh"] !== expectedHarness ||
    dependencies.pnpm !== expectedPnpm ||
    !harness || harness.version !== expectedHarness || !harness.integrity ||
    !pnpm || pnpm.version !== expectedPnpm || !pnpm.integrity) {
  throw new Error("generated package-lock.json does not match the resolved Runtime");
}
const manifest = {
  schemaVersion: 3,
  runtimeVersion: process.env.DSH_RUNTIME_VERSION,
  architecture: process.env.DSH_RUNTIME_ARCHITECTURE,
  nodeVersion: process.env.DSH_RUNTIME_NODE_VERSION,
  harnessVersion: expectedHarness,
  pnpmVersion: expectedPnpm,
  nodeSHA256: process.env.DSH_RUNTIME_NODE_SHA256,
  harnessPackageIntegrity: harness.integrity,
  pnpmPackageIntegrity: pnpm.integrity,
  registry: process.env.DSH_RUNTIME_REGISTRY,
  dataFormat: dataFormatID ? {
    id: dataFormatID,
    compatibleWith,
    migration: process.env.DSH_RUNTIME_DATA_FORMAT_MIGRATION || null
  } : null
};
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
NODE

"$SCRIPT_DIR/runtime-smoke.sh" "$STAGE_DIR"

mkdir -p "$OUTPUT_DIR"
ARTIFACT_NAME="dsh-runtime-$RUNTIME_VERSION-$ARCHITECTURE.tar.gz"
ARTIFACT_PATH="$OUTPUT_DIR/$ARTIFACT_NAME"
tar -czf "$ARTIFACT_PATH" -C "$STAGE_DIR" manifest.json node harness
ARTIFACT_SHA256="$(shasum -a 256 "$ARTIFACT_PATH" | awk '{print $1}')"
export DSH_RUNTIME_ARTIFACT_SHA256="$ARTIFACT_SHA256"
printf '%s  %s\n' "$ARTIFACT_SHA256" "$ARTIFACT_NAME" > "$ARTIFACT_PATH.sha256"
cp "$STAGE_DIR/manifest.json" "$OUTPUT_DIR/manifest-$RUNTIME_VERSION-$ARCHITECTURE.json"

"$NODE_EXECUTABLE" - \
    "$STAGE_DIR/manifest.json" \
    "$OUTPUT_DIR/artifact-$RUNTIME_VERSION-$ARCHITECTURE.json" \
    "$ARTIFACT_BASE_URL" \
    "$ARTIFACT_NAME" <<'NODE'
const fs = require("fs");
const [manifestPath, outputPath, artifactBaseURL, artifactName] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const metadata = {
  runtimeVersion: manifest.runtimeVersion,
  architecture: manifest.architecture,
  nodeVersion: manifest.nodeVersion,
  harnessVersion: manifest.harnessVersion,
  pnpmVersion: manifest.pnpmVersion,
  nodeArchiveSHA256: manifest.nodeSHA256,
  harnessPackageIntegrity: manifest.harnessPackageIntegrity,
  pnpmPackageIntegrity: manifest.pnpmPackageIntegrity,
  dataFormat: manifest.dataFormat,
  artifact: artifactName,
  sha256: process.env.DSH_RUNTIME_ARTIFACT_SHA256,
  url: `${artifactBaseURL}/${artifactName}`,
  manifest: `manifest-${manifest.runtimeVersion}-${manifest.architecture}.json`
};
fs.writeFileSync(outputPath, JSON.stringify(metadata, null, 2) + "\n");
NODE

printf 'Runtime artifact ready: %s\n' "$ARTIFACT_PATH"
printf 'Runtime artifact SHA-256: %s\n' "$ARTIFACT_SHA256"
printf 'Harness version: %s\n' "$HARNESS_VERSION"
printf 'pnpm version: %s\n' "$PNPM_VERSION"
