#!/bin/bash
# Captures KlaD's main window (even on another Space) to $1. Never the full screen.
OUT=${1:-/tmp/klad.png}
WID=$(swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = l.filter { ($0[kCGWindowOwnerName as String] as? String) == "KlaD" && ($0[kCGWindowLayer as String] as? Int) == 0 }
let best = mine.max { a, b in
  let ra = a[kCGWindowBounds as String] as? [String: Double] ?? [:], rb = b[kCGWindowBounds as String] as? [String: Double] ?? [:]
  return (ra["Width"] ?? 0) * (ra["Height"] ?? 0) < (rb["Width"] ?? 0) * (rb["Height"] ?? 0) }
if let best, let b = best[kCGWindowBounds as String] as? [String: Double], (b["Height"] ?? 0) > 200 { print(best[kCGWindowNumber as String] as! Int) }' 2>/dev/null)
[ -n "$WID" ] && screencapture -x -o -l "$WID" "$OUT" && echo "$OUT"
