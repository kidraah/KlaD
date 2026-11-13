#!/bin/bash
# Rebuilds every README image and video from the fictional demo Mac.
#   Scripts/make-media.sh            (needs: make app, ffmpeg, gifski)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=docs/media
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

Scripts/capture-demo.sh "$WORK/raw"
swiftc -O Scripts/render-demo.swift -o "$WORK/render-demo"

for theme in light dark; do
  "$WORK/render-demo" tour "$WORK/raw" $theme "$OUT/tour-$theme.mp4" >/dev/null
  ffmpeg -loglevel error -y -i "$OUT/tour-$theme.mp4" -vf "fps=15,scale=960:-1:flags=lanczos" "$WORK/f-$theme-%04d.png"
  gifski --quiet --fps 15 --quality 72 -o "$OUT/tour-$theme.gif" "$WORK"/f-$theme-*.png
  for shot in sunburst treemap recommendations uninstaller sunburst-focus; do
    "$WORK/render-demo" still "$WORK/raw/$shot-$theme.png" $theme "$WORK/$shot-$theme.png" >/dev/null
    sips -s format jpeg -s formatOptions 88 "$WORK/$shot-$theme.png" --out "$OUT/$shot-$theme.jpg" >/dev/null
  done
done
ls -lh "$OUT"
