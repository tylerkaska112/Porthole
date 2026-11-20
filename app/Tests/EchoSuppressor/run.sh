#!/bin/bash
# The echo gate (Sources/Discord/EchoSuppressor.swift): what counts as the speakers' own sound coming back into the microphone.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
typealias S = EchoSuppressor

var e = S()
check(!e.isEcho(micRMS: 0.01), "nothing is playing: nothing is an echo")
e.played(rms: 0.1)
check(e.isEcho(micRMS: 0.05), "a quiet microphone while the speakers play is taken for their echo")
check(!e.isEcho(micRMS: 0.3), "a voice clearly louder than the speakers is not")
check(e.isEcho(micRMS: 0), "a silent microphone while playing is not sent either")

// The tail: it falls frame by frame and ends
var f = S()
f.played(rms: 0.1)
var frames = 0
while f.isEcho(micRMS: 0.02) && frames < 100 { f.tick(); frames += 1 }
check(frames > 4 && frames < 30, "the room's tail lasts a fraction of a second (\(frames) frames of 20 ms)")
check(!f.isEcho(micRMS: 0.02) && f.playback < 0.1, "then the microphone is free again")

// Several speakers at once: the loudest sets the level
var g = S()
g.played(rms: 0.02); g.played(rms: 0.08); g.played(rms: 0.04)
check(abs(g.playback - 0.08) < 0.0001, "the loudest of several speakers sets the level")

// Very quiet playback is ignored (below the floor)
var h = S()
h.played(rms: 0.003)
check(!h.isEcho(micRMS: 0.001), "speakers that are nearly silent cause no echo")

// It decays to exactly zero
var z = S()
z.played(rms: 0.05)
for _ in 0..<200 { z.tick() }
check(z.playback == 0, "the level ends at zero, not at a tiny number")

check(abs(S.rms([0.5, -0.5, 0.5, -0.5]) - 0.5) < 0.0001 && S.rms([]) == 0, "loudness of a block")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$HERE/../../Sources/Discord/EchoSuppressor.swift" "$OUT/main.swift" 2>&1 | grep -v "^$" | head -10 || true
"$OUT/t"
