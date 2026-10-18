#!/bin/bash
# Compiles the Steam code (sign-in aside) for the Mac with its tests and runs them against a stand-in for Steam's servers.
#   STEAM_LIVE=1 app/Tests/Steam/run.sh     also installs Steam's free sample app (Spacewar, ~2 MB) from the real servers, anonymously.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../Sources/Steam"
OUT="$(mktemp -d)"
cp "$HERE/SteamContentTests.swift" "$OUT/main.swift"
swiftc -swift-version 5 -o "$OUT/steam" "$OUT/main.swift" "$HERE/SteamContentFixture.swift" "$HERE/AppStubs.swift" \
  "$SRC"/{SteamProtocol,SteamZstd,SteamCM,SteamContent,SteamAuth,SteamInstaller,SteamLibraryCM,SteamBinaryKV,SteamVDF,SteamLog,ConcurrencyController,SteamHostBook,SteamCloud,SteamManifestLanguage,SteamSharedApps,SteamAchievements,SteamWorkshop,SteamOverlayWatcher,SteamFriends,SteamStoreInfo}.swift
STEAM_VECTORS="$HERE/vectors" "$OUT/steam"
rm -rf "$OUT"
