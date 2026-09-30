#!/usr/bin/env bash
#
# Derive the AppIcon asset from the light brand source.
#
# `Brand/AppIcon-light.png` is the 1:1 artwork the bundle icon is cut from; the
# asset catalog holds only the sizes macOS asks for, so the set is generated
# rather than hand-cut. Run this after replacing the source:
#
#   Scripts/generate-app-icon.sh
#
# The dark artwork (`Brand/AppIcon-dark.png`) is not part of the catalogue: a
# macOS appiconset cannot carry a dark appearance, so the running app swaps its
# Dock icon from that file instead (`AppIconController`).
set -euo pipefail

cd "$(dirname "$0")/.."

SET="DSH Studio/Assets.xcassets/AppIcon.appiconset"
LIGHT="Brand/AppIcon-light.png"

for source in "$LIGHT" "Brand/AppIcon-dark.png"; do
  [ -f "$source" ] || { echo "missing source: $source" >&2; exit 1; }
done

# File base name → pixels, matching the entries in Contents.json exactly: the
# pixel count is the declared size times the scale, so `16x16` at `2x` is 32.
sizes=(
  "whale-girl-16:16"
  "whale-girl-32-2x:32"
  "whale-girl-32-1x:32"
  "whale-girl-64:64"
  "whale-girl-128-1x:128"
  "whale-girl-256-2x:256"
  "whale-girl-256-1x:256"
  "whale-girl-512-2x:512"
  "whale-girl-512-1x:512"
  "whale-girl-1024:1024"
)

for entry in "${sizes[@]}"; do
  name="${entry%%:*}"
  pixels="${entry##*:}"
  sips -z "$pixels" "$pixels" "$LIGHT" --out "$SET/$name.png" >/dev/null
done

# The running app swaps its Dock icon from these two, chosen by appearance.
for variant in light dark; do
  case "$variant" in
    light) suffix="Light" ;;
    dark) suffix="Dark" ;;
  esac
  imageset="DSH Studio/Assets.xcassets/AppLogo$suffix.imageset"
  mkdir -p "$imageset"
  sips -z 256 256 "Brand/AppIcon-$variant.png" --out "$imageset/AppLogo-$variant-1x.png" >/dev/null
  sips -z 512 512 "Brand/AppIcon-$variant.png" --out "$imageset/AppLogo-$variant-2x.png" >/dev/null
  cat > "$imageset/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "AppLogo-$variant-1x.png",
      "idiom" : "mac",
      "scale" : "1x"
    },
    {
      "filename" : "AppLogo-$variant-2x.png",
      "idiom" : "mac",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
done

echo "wrote ${#sizes[@]} icons into $SET and two AppLogo imagesets"
