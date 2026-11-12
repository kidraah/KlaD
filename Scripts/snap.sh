#!/bin/bash
# Captures the frontmost KlaD window to $1 (no Screen Recording needed for own-user windows here).
OUT=${1:-/tmp/klad.png}
WID=$(swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in l where (w[kCGWindowOwnerName as String] as? String) == "KlaD" { if let b = w[kCGWindowBounds as String] as? [String: Any], let h = b["Height"] as? Double, h > 200 { print(w[kCGWindowNumber as String] as! Int); break } }' 2>/dev/null)
[ -n "$WID" ] && screencapture -x -o -l "$WID" "$OUT" && echo "$OUT"
