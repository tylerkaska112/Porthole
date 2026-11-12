#!/bin/bash
# Runs the SSD library's storage layer (Runtime/SteamStorage.swift, ExternalStorage.swift, SteamKeyValues.swift) on the Mac against throw-away folders: identity marker, paths,
# the catalog, the drive mapping, libraryfolders.vdf and free-space handling.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cp "$HERE/main.swift" "$OUT/main.swift"
swiftc -swift-version 5 -o "$OUT/ssd" "$OUT/main.swift" "$HERE/../../Runtime/SteamStorage.swift" "$HERE/../../Runtime/ExternalStorage.swift" "$HERE/../../Runtime/SteamKeyValues.swift"
"$OUT/ssd"
rm -rf "$OUT"
