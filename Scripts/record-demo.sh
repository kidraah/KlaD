#!/bin/bash
# Records the live README demo: Scripts/record-demo.sh <light|dark> <out-dir>
# Takes over the mouse for ~40 s (needs Accessibility + Screen Recording).
set -euo pipefail
cd "$(dirname "$0")/.."
THEME=${1:-light}; OUT=${2:-docs/media}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
swiftc -O -swift-version 5 Scripts/record-demo.swift -o "$WORK/record-demo" 2>/dev/null
swiftc -O Scripts/render-demo.swift -o "$WORK/render-demo" 2>/dev/null

osascript -e 'quit app "KlaD"' >/dev/null 2>&1 || true
while pgrep -x KlaD >/dev/null; do sleep 0.3; done
defaults write org.klad.KlaD "NSWindow Frame main-AppWindow-1" "240 75 1440 900 0 0 1920 1050 "
open build/KlaD.app --args --appearance "$THEME" --demo      # --demo must be last
sleep 4
"$WORK/record-demo" "$WORK/capture.mov" "$WORK/capture.json"
osascript -e 'quit app "KlaD"' >/dev/null 2>&1 || true
defaults delete org.klad.KlaD "NSWindow Frame main-AppWindow-1" >/dev/null 2>&1 || true

mkdir -p "$OUT"
"$WORK/render-demo" recording "$WORK/capture.mov" "$THEME" "$OUT/live-$THEME.mp4"
ffmpeg -loglevel error -y -i "$OUT/live-$THEME.mp4" -vf "fps=15,scale=960:-1:flags=lanczos" "$WORK/g-%04d.png"
gifski --quiet --fps 15 --quality 72 -o "$OUT/live-$THEME.gif" "$WORK"/g-*.png
[ -n "${KEEP_CAPTURE:-}" ] && cp "$WORK/capture.mov" "$WORK/capture.json" "$KEEP_CAPTURE/"
ls -lh "$OUT/live-$THEME".*
