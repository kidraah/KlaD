#!/bin/bash
# Note: --demo must come last (a following --flag stops the window opening).
# Captures README screenshots from the demo build: Scripts/capture-demo.sh <out-dir>
set -euo pipefail
OUT=${1:-docs/media/raw}
mkdir -p "$OUT"
APP=build/KlaD.app
shot() {   # name, args...
  local name=$1; shift
  for attempt in 1 2 3 4; do
    osascript -e 'quit app "KlaD"' >/dev/null 2>&1 || true
    while pgrep -x KlaD >/dev/null; do sleep 0.3; done
    # Same window size and place for every shot (main display, 1440×900).
    defaults write org.klad.KlaD "NSWindow Frame main-AppWindow-1" "240 75 1440 900 0 0 1920 1050 "
    open "$APP" --args "$@"
    sleep 5
    if Scripts/snap.sh "$OUT/$name.png" >/dev/null; then echo "captured $name"; return; fi
  done
  echo "FAILED $name" >&2
}
shot sunburst-light        --appearance light --demo
shot sunburst-focus-light  --appearance light --focus Projects --select Projects/render-engine --demo
shot treemap-light         --appearance light --mode treemap --demo
shot recommendations-light --appearance light --section recommendations --demo
shot sunburst-dark         --appearance dark --demo
shot sunburst-focus-dark   --appearance dark --focus Projects --select Projects/render-engine --demo
shot treemap-dark          --appearance dark --mode treemap --demo
shot recommendations-dark  --appearance dark --section recommendations --demo
shot uninstaller-light     --appearance light --uninstaller VLC --demo
shot uninstaller-dark      --appearance dark --uninstaller VLC --demo
osascript -e 'quit app "KlaD"' >/dev/null 2>&1 || true
defaults delete org.klad.KlaD "NSWindow Frame main-AppWindow-1" >/dev/null 2>&1 || true
