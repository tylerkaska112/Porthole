#!/bin/bash
# Host tests for the hardware keyboard and mouse mapping (the pure section of HardwareInput.swift). usage: app/Tests/HardwareInput/run.sh
set -eu
cd "$(dirname "$0")"
OUT=$(mktemp -d)
SRC=../../Sources/Core/HardwareInput.swift
# Only the part between the two markers: Foundation, no UIKit, no engine symbols.
awk '/^\/\/ MARK: - Pure input mapping/{on=1; next} /^\/\/ MARK: - Device glue/{on=0} on' "$SRC" > "$OUT/pure.swift"
if grep -vE "^\s*//" "$OUT/pure.swift" | grep -qE "UIKit|UITouch|winios_|GameController"; then echo "FAIL  the pure section uses a platform symbol"; exit 1; fi
swiftc -o "$OUT/t" "$OUT/pure.swift" main.swift 2>&1 | grep -E "error" || true
"$OUT/t"
