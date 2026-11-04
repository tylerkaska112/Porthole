#!/bin/bash
# Compiles the Reports tab's list logic (filters, ordering, summary, a game's breakdown) with the verdict types and runs the checks.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library -o "$OUT/t" ../../Sources/Compat/CompatBadges.swift ../../Sources/Compat/ReportsLogic.swift main.swift 2>&1 | grep -E "error" || true
"$OUT/t"
