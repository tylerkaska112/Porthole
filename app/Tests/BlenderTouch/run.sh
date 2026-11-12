#!/bin/bash
# Host tests for the touch gestures (TouchGestureEngine.swift), including Blender's pan / zoom / orbit. usage: app/Tests/BlenderTouch/run.sh
set -eu
cd "$(dirname "$0")"
OUT=$(mktemp -d)
swiftc -o "$OUT/t" ../../Sources/UI/TouchGestureEngine.swift main.swift 2>&1 | grep -E "error" || true
"$OUT/t"
