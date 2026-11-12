#!/bin/bash
# Runs the auto-fix rules (Sources/Core/AutoFix.swift) against excerpts of the logs people sent in (fixtures/rNNN.log: the lines the rules look at, from compatibility reports 122-182).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cp "$HERE/main.swift" "$OUT/main.swift"
swiftc -swift-version 5 -o "$OUT/autofix" "$OUT/main.swift" "$HERE/../../Sources/Core/AutoFix.swift" "$HERE/../../Sources/Core/AutoFixRemote.swift" "$HERE/../../Sources/Core/LastRun.swift" "$HERE/../../Sources/Core/DocsDiagnosis.swift" "$HERE/../../Sources/Core/DocsDiagnosis.generated.swift" "$HERE/Stubs.swift"
"$OUT/autofix" "$HERE/fixtures"
rm -rf "$OUT"
