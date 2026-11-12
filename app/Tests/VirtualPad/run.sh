#!/bin/bash
# Runs the on-screen controller's maths (Sources/Core/VirtualPadModel.swift): sticks, the direction pad, the face buttons, merging with a real controller, and the layout on screens of many sizes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cp "$HERE/main.swift" "$OUT/main.swift"
swiftc -swift-version 5 -o "$OUT/vp" "$OUT/main.swift" "$HERE/../../Sources/Core/VirtualPadModel.swift" "$HERE/../../Sources/Core/ControllerKind.swift"
"$OUT/vp"
rm -rf "$OUT"
