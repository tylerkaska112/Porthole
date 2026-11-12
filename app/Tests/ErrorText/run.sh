#!/bin/bash
# Runs ErrorText (Sources/Core/ErrorText.swift): system errors in plain sentences, and the app's own errors passed through.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cp "$HERE/main.swift" "$OUT/main.swift"
swiftc -swift-version 5 -o "$OUT/et" "$OUT/main.swift" "$HERE/../../Sources/Core/ErrorText.swift"
"$OUT/et"
rm -rf "$OUT"
