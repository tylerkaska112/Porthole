#!/bin/bash
# Compiles SavedSignInRule (Sources/Core/SavedSignInRule.swift) for the Mac and checks when a start may use Steam's saved sign-in.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
let now = Date()
func rule(enabled: Bool = true, override: Int? = nil, settingOn: Bool = true, always: Bool = false, forced: Bool = false, saved: Bool = true, verified: Date? = Date().addingTimeInterval(-3600)) -> (use: Bool, why: String) {
    SavedSignInRule.decide(enabled: enabled, override: override, settingOn: settingOn, alwaysOffline: always, forcedOnline: forced, accountSaved: saved, verified: verified, now: now)
}
check(rule().use, "a game that started online an hour ago starts from the saved sign-in")
check(!rule(enabled: false).use, "offline logon switched off: online")
check(!rule(settingOn: false).use, "switched off in Settings: online")
check(rule(override: 0, settingOn: false).use, "the game's own choice for the saved sign-in wins over the setting")
check(!rule(override: 1).use, "the game asks for online: online")
check(!rule(forced: true).use, "after Steam refused it once: online")
check(!rule(override: 0, forced: true).use, "even when the game asked for it, a refusal means one online start")
check(!rule(saved: false).use, "no offline sign-in saved yet: online")
check(!rule(verified: nil).use, "a game that never started online: online")
check(rule(verified: now.addingTimeInterval(-13 * 86400)).use, "13 days after the online start: still the saved sign-in")
check(!rule(verified: now.addingTimeInterval(-15 * 86400)).use, "15 days after: online, which renews it")
check(rule(verified: now.addingTimeInterval(+60)).use, "a clock that moved back does not break it")
check(rule(verified: now.addingTimeInterval(-3 * 3600)).why.contains("3 hours"), "the reason names the age")
// "Start Steam games offline" (Settings) and "Offline every time" (the game's own choice 2)
check(rule(always: true).use, "start offline switched on: a ready game starts from the saved sign-in")
check(rule(settingOn: false, always: true).use, "start offline wins over the saved sign-in switch being off")
check(rule(always: true).why.hasPrefix("offline start chosen"), "the reason says the offline start was chosen")
check(!rule(always: true, saved: false).use, "start offline, nothing saved yet: online (which saves one)")
check(!rule(always: true, verified: nil).use, "start offline, game never started online: online")
check(!rule(always: true, forced: true).use, "start offline, Steam refused it last time: one online start")
check(!rule(always: true, verified: now.addingTimeInterval(-15 * 86400)).use, "start offline, saved sign-in 15 days old: online, which renews it")
check(!rule(enabled: false, always: true).use, "offline logon removed (env): never offline")
check(!rule(override: 1, always: true).use, "the game asks for online: online even with start offline on")
check(rule(override: 0, always: false).use, "the game's saved sign-in choice still works with start offline off")
check(rule(override: 2).use, "the game's own offline choice starts offline with the Settings switch off")
check(rule(override: 2, settingOn: false).use, "the game's offline choice wins over the saved sign-in switch being off")
check(!rule(override: 2, saved: false).use, "the game's offline choice, nothing saved yet: online")
check(!rule(override: 2, forced: true).use, "the game's offline choice, Steam refused it last time: one online start")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/SavedSignInRule.swift"
"$OUT/t"
rm -rf "$OUT"
