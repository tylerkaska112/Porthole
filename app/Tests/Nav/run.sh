#!/bin/bash
# Host tests for the controller navigation logic. usage: app/Tests/Nav/run.sh
set -eu
cd "$(dirname "$0")"
OUT=$(mktemp -d)
swiftc -o "$OUT/t" ../../Sources/UI/Kit/FocusSpatial.swift ../../Sources/UI/Kit/FocusScope.swift ../../Sources/UI/Kit/NavRepeater.swift ../../Sources/Core/PadAuto.swift ../../Sources/Core/ControllerKind.swift ../../Sources/Core/PadChord.swift ../../Sources/Core/PadRemap.swift ../../Sources/Core/PadActions.swift ../../Sources/Core/TouchPadControls.swift ../../Sources/Core/VirtualPadModel.swift Stubs.swift main.swift 2>&1 | grep -E "error" || true
"$OUT/t"
