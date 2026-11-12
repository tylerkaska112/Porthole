#!/bin/bash
# Runs the Lossless Scaling licence logic (Sources/Core/LosslessLicence.swift): receipts, their limits and the sealed file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cp "$HERE/main.swift" "$OUT/main.swift"
swiftc -swift-version 5 -o "$OUT/licence" "$OUT/main.swift" "$HERE/../../Sources/Core/LosslessLicence.swift" "$HERE/../../Sources/Core/LosslessShaders.swift"
"$OUT/licence"
rm -rf "$OUT"
