#!/bin/bash
# Compiles SideBySide.swift (it only needs Foundation) with its checks and runs them.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
swiftc -o "$OUT/t" ../../Sources/Core/SideBySide.swift main.swift 2>&1 | grep -v "^$" || true
"$OUT/t"
