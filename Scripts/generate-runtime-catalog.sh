#!/usr/bin/env bash
set -euo pipefail

# Combines architecture-specific Builder metadata into the catalog bundled by
# a release App. The catalog contains immutable artifact URLs and checksums;
# it is not a runtime "latest" endpoint.

RUNTIME_VERSION="${RUNTIME_VERSION:-${1:-}}"
OUTPUT_PATH="${OUTPUT_PATH:-${2:-}}"

die() {
    printf 'generate-runtime-catalog: %s\n' "$1" >&2
    exit 1
}

command -v node >/dev/null 2>&1 || die "missing required command: node"
[ -n "$RUNTIME_VERSION" ] || die "usage: $0 RUNTIME_VERSION OUTPUT_PATH ARTIFACT_METADATA..."
[ -n "$OUTPUT_PATH" ] || die "output path is required"
[ "$#" -ge 4 ] || die "at least two architecture metadata files are required"
shift 2

for metadata in "$@"; do
    [ -f "$metadata" ] || die "metadata file does not exist: $metadata"
done

mkdir -p "$(dirname "$OUTPUT_PATH")"
node - "$RUNTIME_VERSION" "$OUTPUT_PATH" "$@" <<'NODE'
const fs = require("fs");
const [runtimeVersion, outputPath, ...metadataPaths] = process.argv.slice(2);

const releases = metadataPaths.map((metadataPath) => {
  const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
  if (metadata.runtimeVersion !== runtimeVersion) {
    throw new Error(`runtime version mismatch in ${metadataPath}`);
  }
  if (!metadata.url || !metadata.sha256 || !metadata.architecture) {
    throw new Error(`incomplete artifact metadata in ${metadataPath}`);
  }
  return {
    runtimeVersion: metadata.runtimeVersion,
    architecture: metadata.architecture,
    nodeVersion: metadata.nodeVersion,
    harnessVersion: metadata.harnessVersion,
    pnpmVersion: metadata.pnpmVersion,
    nodeArchiveSHA256: metadata.nodeArchiveSHA256,
    harnessPackageIntegrity: metadata.harnessPackageIntegrity,
    pnpmPackageIntegrity: metadata.pnpmPackageIntegrity,
    artifact: {
      runtimeVersion: metadata.runtimeVersion,
      architecture: metadata.architecture,
      url: metadata.url,
      sha256: metadata.sha256
    }
  };
});

const architectures = new Set(releases.map((release) => release.architecture));
if (architectures.size !== releases.length || !architectures.has("darwin-arm64") || !architectures.has("darwin-x64")) {
  throw new Error("catalog must contain exactly one arm64 and one x86_64 Runtime");
}

fs.writeFileSync(outputPath, JSON.stringify({
  schemaVersion: 1,
  runtimeVersion,
  releases
}, null, 2) + "\n");
NODE

printf 'Runtime catalog ready: %s\n' "$OUTPUT_PATH"
