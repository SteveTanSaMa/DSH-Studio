#!/usr/bin/env bash
set -euo pipefail

# Runs the checks that must pass before a Runtime artifact can be published.

RUNTIME_ROOT="${1:-}"
[ -n "$RUNTIME_ROOT" ] || { printf 'runtime-smoke: runtime root is required\n' >&2; exit 1; }
[ -d "$RUNTIME_ROOT" ] || { printf 'runtime-smoke: root does not exist: %s\n' "$RUNTIME_ROOT" >&2; exit 1; }

command -v node >/dev/null 2>&1 || { printf 'runtime-smoke: host node is required\n' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { printf 'runtime-smoke: curl is required\n' >&2; exit 1; }

manifest_value() {
    local key="$1"
    node -e '
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const value = manifest[process.argv[2]];
if (value === undefined || value === null) process.exit(1);
process.stdout.write(String(value));
' "$RUNTIME_ROOT/manifest.json" "$key"
}

ARCHITECTURE="$(manifest_value architecture)"
RUNTIME_VERSION="$(manifest_value runtimeVersion)"
NODE_VERSION="$(manifest_value nodeVersion)"
HARNESS_VERSION="$(manifest_value harnessVersion)"
PNPM_VERSION="$(manifest_value pnpmVersion)"

NODE_EXECUTABLE="$RUNTIME_ROOT/node/$ARCHITECTURE/bin/node"
HARNESS_ROOT="$RUNTIME_ROOT/harness/$ARCHITECTURE/$HARNESS_VERSION"
HARNESS_ENTRY="$HARNESS_ROOT/node_modules/@deepseek-ai/dsh/lib/bin.js"
PNPM_EXECUTABLE="$HARNESS_ROOT/node_modules/.bin/pnpm"
PTY_BINARY="$HARNESS_ROOT/node_modules/node-pty/prebuilds/$ARCHITECTURE/pty.node"
SPAWN_HELPER="$HARNESS_ROOT/node_modules/node-pty/prebuilds/$ARCHITECTURE/spawn-helper"

[ -x "$NODE_EXECUTABLE" ] || { printf 'runtime-smoke: Node is not executable\n' >&2; exit 1; }
[ -f "$HARNESS_ENTRY" ] || { printf 'runtime-smoke: Harness entry is missing\n' >&2; exit 1; }
[ -x "$PNPM_EXECUTABLE" ] || { printf 'runtime-smoke: pnpm shim is not executable\n' >&2; exit 1; }
[ -f "$PTY_BINARY" ] || { printf 'runtime-smoke: node-pty binary is missing\n' >&2; exit 1; }
[ -x "$SPAWN_HELPER" ] || { printf 'runtime-smoke: node-pty helper is not executable\n' >&2; exit 1; }

ACTUAL_NODE_VERSION="$($NODE_EXECUTABLE --version | tr -d '[:space:]')"
[ "$ACTUAL_NODE_VERSION" = "v$NODE_VERSION" ] || {
    printf 'runtime-smoke: expected Node v%s, got %s\n' "$NODE_VERSION" "$ACTUAL_NODE_VERSION" >&2
    exit 1
}

ACTUAL_PNPM_VERSION="$("$PNPM_EXECUTABLE" --version 2>/dev/null || true)"
ACTUAL_PNPM_VERSION="$(printf '%s' "$ACTUAL_PNPM_VERSION" | tr -d '[:space:]')"
[ "$ACTUAL_PNPM_VERSION" = "$PNPM_VERSION" ] || {
    printf 'runtime-smoke: expected pnpm %s, got %s\n' "$PNPM_VERSION" "$ACTUAL_PNPM_VERSION" >&2
    exit 1
}

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dsh-runtime-smoke.XXXXXX")"
LOG_FILE="$TEMP_ROOT/harness.log"
RESPONSE_FILE="$TEMP_ROOT/health.json"
DSH_HOME="$TEMP_ROOT/dsh-home"
mkdir -p "$DSH_HOME"

cleanup() {
    if [ -n "${HARNESS_PID:-}" ] && kill -0 "$HARNESS_PID" 2>/dev/null; then
        kill "$HARNESS_PID" 2>/dev/null || true
        wait "$HARNESS_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

(
    cd "$TEMP_ROOT"
    DSH_HOME="$DSH_HOME" \
    DSH_TELEMETRY_DISABLED=1 \
    PATH="$(dirname "$NODE_EXECUTABLE"):$(dirname "$PNPM_EXECUTABLE"):$PATH" \
        "$NODE_EXECUTABLE" "$HARNESS_ENTRY" web --host 127.0.0.1 --port 0
) >"$LOG_FILE" 2>&1 &
HARNESS_PID=$!

READY_URL=""
HEALTHY=0
for _ in $(seq 1 120); do
    READY_URL="$(sed -n 's/.*\(http:\/\/127\.0\.0\.1:[0-9][0-9]*\).*/\1/p' "$LOG_FILE" | tail -n 1 || true)"
    if [ -n "$READY_URL" ]; then
        if curl -fsS -X POST \
            -H 'Content-Type: application/json' \
            --data '{"type":"client-request","rpcId":"runtime-smoke","method":"host.describe","payload":{}}' \
            "$READY_URL/api/host.describe" > "$RESPONSE_FILE"; then
            if node -e '
const fs = require("fs");
const response = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (!response.result || response.result.ok !== true) process.exit(1);
' "$RESPONSE_FILE"; then
                HEALTHY=1
                break
            fi
        fi
    fi
    if ! kill -0 "$HARNESS_PID" 2>/dev/null; then
        break
    fi
    sleep 0.5
done

if [ "$HEALTHY" -ne 1 ]; then
    printf 'runtime-smoke: Harness did not pass host.describe\n' >&2
    sed -n '1,240p' "$LOG_FILE" >&2 || true
    exit 1
fi

printf 'Runtime smoke passed: %s / Harness %s / Node %s / pnpm %s\n' \
    "$RUNTIME_VERSION" "$HARNESS_VERSION" "$NODE_VERSION" "$PNPM_VERSION"
