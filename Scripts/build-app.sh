#!/usr/bin/env bash
set -euo pipefail

# Builds DSH Studio. Runtime artifacts and the signed Runtime catalog are
# discovered from the independent DSH-Studio-Runtime release repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$REPOSITORY_ROOT/DSH Studio.xcodeproj"
SCHEME="${SCHEME:-DSH Studio}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPOSITORY_ROOT/.build/DerivedData}"
RUNTIME_CATALOG_PUBLIC_KEY="${RUNTIME_CATALOG_PUBLIC_KEY:-}"

die() {
    printf 'build-app: %s\n' "$1" >&2
    exit 1
}

if [ "$CONFIGURATION" = "Release" ] && [ -z "$RUNTIME_CATALOG_PUBLIC_KEY" ]; then
    die "Release build needs RUNTIME_CATALOG_PUBLIC_KEY for remote discovery"
fi

exec xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    RUNTIME_CATALOG_PUBLIC_KEY="$RUNTIME_CATALOG_PUBLIC_KEY" \
    "$@"
