#!/bin/bash
# Runs ProgramRepair (Sources/Core/ProgramRepair.swift) against folders made on the Mac, including the damaged path real reports had.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cp "$HERE/main.swift" "$OUT/main.swift"
swiftc -swift-version 5 -o "$OUT/repair" "$OUT/main.swift" "$HERE/../../Sources/Core/ProgramRepair.swift"
"$OUT/repair"
rm -rf "$OUT"
