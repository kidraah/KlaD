#!/bin/bash
# Runs `swift test` with Swift Testing wired up on Command-Line-Tools-only Macs.
# Usage: Scripts/test.sh [extra swift test args, e.g. --filter KlaDCoreTests]
# Works from any package directory (the root package or any nested package).
set -euo pipefail
CLT=/Library/Developer/CommandLineTools
FW="$CLT/Library/Developer/Frameworks"
EXTRA=()
if [[ "$(xcode-select -p 2>/dev/null)" == "$CLT"* && -d "$FW/Testing.framework" ]]; then
  EXTRA=(-Xswiftc -F -Xswiftc "$FW"
         -Xlinker -rpath -Xlinker "$FW"
         -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib")
fi
exec swift test "${EXTRA[@]}" "$@"
