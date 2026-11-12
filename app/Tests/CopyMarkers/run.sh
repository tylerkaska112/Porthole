#!/bin/bash
# Runs CopyMarkers (Sources/Core/CopyMarkers.swift) against throw-away folders.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cp "$HERE/main.swift" "$OUT/main.swift"
swiftc -swift-version 5 -o "$OUT/copymarkers" "$OUT/main.swift" "$HERE/../../Sources/Core/CopyMarkers.swift"
"$OUT/copymarkers"
rm -rf "$OUT"
