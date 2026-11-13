#!/bin/bash
# Rebuilds the README screenshots from the fictional demo Mac.
#   Scripts/make-media.sh   (needs: make app). The live video: Scripts/record-demo.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=docs/media
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

Scripts/capture-demo.sh "$WORK/raw"
swiftc -O Scripts/render-demo.swift -o "$WORK/render-demo"

for theme in light dark; do
  for shot in sunburst treemap recommendations uninstaller sunburst-focus; do
    "$WORK/render-demo" still "$WORK/raw/$shot-$theme.png" $theme "$WORK/$shot-$theme.png" >/dev/null
    sips -s format jpeg -s formatOptions 88 "$WORK/$shot-$theme.png" --out "$OUT/$shot-$theme.jpg" >/dev/null
  done
done
ls -lh "$OUT"
