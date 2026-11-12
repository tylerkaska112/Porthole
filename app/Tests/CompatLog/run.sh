#!/bin/bash
# Runs the report-log picker (Sources/Compat/CompatLogPicker.swift): which of a game's session logs go with its name.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cp "$HERE/main.swift" "$OUT/main.swift"
swiftc -swift-version 5 -o "$OUT/picker" "$OUT/main.swift" "$HERE/../../Sources/Compat/CompatLogPicker.swift"
"$OUT/picker"
rm -rf "$OUT"
