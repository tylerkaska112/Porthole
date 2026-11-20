#!/bin/bash
# Recognising an anti-cheat from a game's files (Sources/Epic/EpicAntiCheat.swift).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
typealias E = EpicAntiCheat
check(E.detect(paths: ["FallGuys_client_game.exe", "EasyAntiCheat/EasyAntiCheat_Setup.exe", "EasyAntiCheat/Settings.json"]) == "Easy Anti-Cheat", "Fall Guys' files: Easy Anti-Cheat")
check(E.detect(paths: ["TslGame/Binaries/Win64/BattlEye/BEService_x64.exe", "TslGame/Binaries/Win64/TslGame.exe"]) == "BattlEye", "PUBG's files: BattlEye")
check(E.detect(paths: ["Engine\\Binaries\\ThirdParty\\EasyAntiCheat\\Win64\\EasyAntiCheat.dll"]) == "Easy Anti-Cheat", "an Unreal game keeps it deeper, with backslashes")
check(E.detect(paths: ["Game/EasyAntiCheat_EOS/EasyAntiCheat_EOS_Setup.exe"]) == "Easy Anti-Cheat", "the EOS flavour")
check(E.detect(paths: ["a/EasyAntiCheat/x.dll", "b/BattlEye/BEClient_x64.dll"]) == "Easy Anti-Cheat and BattlEye", "two are both named, in a fixed order")
check(E.detect(paths: ["Binaries/EQU8_helper_64.exe"]) == "EQU8" && E.detect(paths: ["pbsvc.exe"]) == "PunkBuster" && E.detect(paths: ["x/npggNT.des"]) == "GameGuard", "the others")
// What must not count.
check(E.detect(paths: ["Game.exe", "Data/Textures/anticheat_poster.png", "Engine/Binaries/Win64/Client/EOSSDK-Win64-Shipping.dll", "Content/Paks/pakchunk0.pak"]) == nil, "an ordinary game: nothing")
check(E.detect(paths: ["EpicOnlineServices/EOSSDK-Win64-Shipping.dll", "Binaries/crashpad_handler.exe", "Redist/vc_redist.x64.exe"]) == nil, "Epic Online Services alone is not an anti-cheat")
check(E.detect(paths: ["Strategy/Berserk/BEvents.dat", "Data/beacon.png"]) == nil, "names that only start with the same letters are not BattlEye")
check(E.detect(paths: []) == nil && E.detect(paths: ["", "/", "\\"]) == nil, "nothing, and odd paths")
check(E.warning("BattlEye").contains("BattlEye") && E.warning("BattlEye").contains("online"), "the warning names it")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Epic/EpicAntiCheat.swift"
"$OUT/t"
rm -rf "$OUT"
