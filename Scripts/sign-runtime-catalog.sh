#!/usr/bin/env bash
set -euo pipefail

# Signs an immutable Runtime catalog with an Ed25519 private key. The private
# key is supplied by CI or a local secret store and is never written to the
# repository. The app verifies the resulting envelope with its bundled public
# key before using any remote release metadata.

INPUT_PATH="${1:-}"
OUTPUT_PATH="${2:-}"
PRIVATE_KEY_PATH="${RUNTIME_CATALOG_PRIVATE_KEY_PATH:-}"
PRIVATE_KEY_BASE64="${RUNTIME_CATALOG_PRIVATE_KEY_BASE64:-}"
KEY_ID="${RUNTIME_CATALOG_KEY_ID:-runtime-catalog-v1}"

die() {
    printf 'sign-runtime-catalog: %s\n' "$1" >&2
    exit 1
}

[ -f "$INPUT_PATH" ] || die "catalog input does not exist: $INPUT_PATH"
[ -n "$OUTPUT_PATH" ] || die "usage: $0 CATALOG_JSON OUTPUT_SIGNED_JSON"
[ -n "$PRIVATE_KEY_PATH" ] || [ -n "$PRIVATE_KEY_BASE64" ] || die "set RUNTIME_CATALOG_PRIVATE_KEY_PATH or RUNTIME_CATALOG_PRIVATE_KEY_BASE64"
command -v node >/dev/null 2>&1 || die "missing required command: node"

mkdir -p "$(dirname "$OUTPUT_PATH")"
node - "$INPUT_PATH" "$OUTPUT_PATH" "$PRIVATE_KEY_PATH" "$PRIVATE_KEY_BASE64" "$KEY_ID" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");

const [inputPath, outputPath, privateKeyPath, privateKeyBase64, keyID] = process.argv.slice(2);
const payload = fs.readFileSync(inputPath);
const keyMaterial = privateKeyBase64
  ? Buffer.from(privateKeyBase64, "base64")
  : fs.readFileSync(privateKeyPath);
const privateKey = crypto.createPrivateKey(keyMaterial);
const signature = crypto.sign(null, payload, privateKey);

const envelope = {
  schemaVersion: 1,
  keyID,
  payload: payload.toString("base64"),
  signature: signature.toString("base64")
};
fs.writeFileSync(outputPath, JSON.stringify(envelope, null, 2) + "\n");

const publicDER = crypto.createPublicKey(privateKey).export({ format: "der", type: "spki" });
console.log(`Runtime catalog signed: ${outputPath}`);
console.log(`Runtime catalog public key (base64): ${publicDER.subarray(-32).toString("base64")}`);
NODE
