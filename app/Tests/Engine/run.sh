#!/bin/bash
# Compiles the engine-options code (EngineOptions, PadActions, the save-backup zip code, and Madeira's MadeiraConfig) with stand-ins for the app's types and runs the checks.
# HOME is a scratch folder, so nothing is written to the real Documents or Application Support.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/home"
swiftc -parse-as-library -o "$OUT/t" ../../Sources/Core/EngineOptions.swift ../../Sources/Core/PadActions.swift ../../Sources/Core/TouchPadControls.swift ../../Sources/Core/VirtualPadModel.swift ../../Sources/Core/ControllerKind.swift ../../Sources/Core/SaveBackup.swift ../../Sources/Core/BindSets.swift ../../Sources/Core/BindsShare.swift ../../Sources/Core/RecommendedSettings.swift ../../Sources/Core/AutoBackup.swift ../../Sources/Compat/CompatBadges.swift ../../Runtime/MadeiraConfig.swift ../../Runtime/GPUCards.swift ../../Sources/Core/GameFixes.swift Stubs.swift main.swift 2>&1 | grep -E "error" || true
HOME="$OUT/home" CFFIXED_USER_HOME="$OUT/home" "$OUT/t"
