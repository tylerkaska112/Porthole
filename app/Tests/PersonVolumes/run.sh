#!/bin/bash
# Compiles PersonVolumes for the Mac and checks per-person volume and mute, and how they are remembered.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

var p = PersonVolumes()
check(p.gain("a") == 1 && p.volume("a") == 100 && !p.isMuted("a") && p.gains.isEmpty, "everybody starts at normal")
p.setVolume("a", 150); check(p.gain("a") == 1.5 && p.volume("a") == 150 && p.gains == ["a": 1.5], "150 % is one and a half times")
p.setVolume("a", 100); check(p.gains.isEmpty, "back to 100 % keeps nothing")
p.setVolume("a", 900); check(p.volume("a") == 200, "held to 200 %")
p.setVolume("a", -5); check(p.volume("a") == 0 && p.gain("a") == 0, "held to 0 %")
p.setVolume("a", 60.4); check(p.volume("a") == 60, "rounded")
p.setMuted("a", true); check(p.gain("a") == 0 && p.volume("a") == 60 && p.isMuted("a"), "muting keeps the volume that was set")
p.setMuted("a", false); check(abs(p.gain("a") - 0.6) < 0.0001, "unmuting brings it back")
p.setMuted("b", true); check(p.gains["b"] == 0 && p.gains.count == 2, "somebody muted at 100 % is listed with gain 0")

let suite = UserDefaults(suiteName: "porthole.test.personvolumes")!
suite.removePersistentDomain(forName: "porthole.test.personvolumes")
p.save(suite)
let q = PersonVolumes.load(suite)
check(q == p && q.isMuted("b") && q.volume("a") == 60, "what was set is there after a restart")
check(PersonVolumes.load(UserDefaults(suiteName: "porthole.test.empty")!) == PersonVolumes(), "nothing saved = everybody normal")
suite.removePersistentDomain(forName: "porthole.test.personvolumes")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Discord/PersonVolumes.swift"
"$OUT/t"
rm -rf "$OUT"
