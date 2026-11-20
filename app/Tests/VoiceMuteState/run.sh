#!/bin/bash
# Compiles VoiceMuteState for the Mac and checks how mute and deafen belong together.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

var s = VoiceMuteState()
check(!s.micMuted && !s.deafened, "starts open")
s.setMicMuted(true); check(s.micMuted && !s.deafened, "mute alone does not deafen")
s.setMicMuted(false); check(!s.micMuted, "unmute")

s.setDeafened(true); check(s.deafened && s.micMuted, "deafening also mutes the microphone")
s.setDeafened(false); check(!s.deafened && !s.micMuted, "undeafening puts an open microphone back")

s.setMicMuted(true); s.setDeafened(true); s.setDeafened(false)
check(!s.deafened && s.micMuted, "a microphone that was muted before the deafen stays muted after it")

s = VoiceMuteState(); s.setDeafened(true); s.setMicMuted(false)
check(!s.deafened && !s.micMuted, "unmuting while deafened undoes the deafen")

s = VoiceMuteState(); s.setDeafened(true); s.setMicMuted(true)
check(s.deafened && s.micMuted, "muting while deafened changes nothing visible")
s.setDeafened(false); check(!s.deafened && s.micMuted, "...but the microphone stays muted when the deafen ends")

s = VoiceMuteState(); s.setDeafened(true); s.setDeafened(true); s.setDeafened(false)
check(!s.micMuted, "deafening twice does not remember the muted state it caused")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Discord/VoiceMuteState.swift"
"$OUT/t"
rm -rf "$OUT"
