#!/bin/bash
# The offer to switch to touch controls for a game that ignores the on-screen controller (Sources/Core/LayoutSuggestion.swift).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

var s = LayoutSuggestion()
s.begin(now: 100, reads: 0)
check(!s.update(now: 110, reads: 0, eligible: true), "not before the grace period")
check(!s.update(now: 119.9, reads: 0, eligible: true), "still not just before it")
check(s.update(now: 120, reads: 0, eligible: true), "after twenty seconds of no controller reads: the offer")
check(!s.update(now: 121, reads: 0, eligible: true) && !s.update(now: 500, reads: 0, eligible: true), "and only once")

var reads = LayoutSuggestion()
reads.begin(now: 0, reads: 5)
check(!reads.update(now: 10, reads: 6, eligible: true), "a game that reads the controller is never offered anything")
check(!reads.update(now: 300, reads: 6, eligible: true), "not later either")

var late = LayoutSuggestion()
late.begin(now: 0, reads: 0)
check(!late.update(now: 19, reads: 0, eligible: true) && !late.update(now: 21, reads: 3, eligible: true), "reads that start before the offer cancel it")
check(!late.update(now: 400, reads: 3, eligible: true), "for the rest of the run")

var blocked = LayoutSuggestion()
blocked.begin(now: 0, reads: 0)
check(!blocked.update(now: 30, reads: 0, eligible: false), "not while something is in the way (the menu, a real controller)")
check(!blocked.update(now: 31, reads: 0, eligible: true), "once it is clear the grace period starts again: no card at once (someone just turned the pad on)")
check(!blocked.update(now: 49.9, reads: 0, eligible: true) && blocked.update(now: 50, reads: 0, eligible: true), "and the offer comes twenty seconds after the last blocked second")

let defaults = UserDefaults(suiteName: "layout-suggestion-test-\(getpid())")!
defaults.removePersistentDomain(forName: "layout-suggestion-test-\(getpid())")
check(LayoutSuggestion.mayAsk(gameID: "g1", defaults: defaults), "a game that was never asked may be")
LayoutSuggestion.remember(gameID: "g1", defaults: defaults)
check(!LayoutSuggestion.mayAsk(gameID: "g1", defaults: defaults) && LayoutSuggestion.mayAsk(gameID: "g2", defaults: defaults), "an answered game is not asked again, others are")
LayoutSuggestion.remember(gameID: "g1", defaults: defaults)
check((defaults.stringArray(forKey: LayoutSuggestion.askedKey) ?? []).count == 1, "remembering twice keeps one entry")
defaults.set(true, forKey: LayoutSuggestion.offKey)
check(!LayoutSuggestion.mayAsk(gameID: "g2", defaults: defaults), "the switch that turns the offer off stops it for every game")
for i in 0..<400 { LayoutSuggestion.remember(gameID: "x\(i)", defaults: defaults) }
check((defaults.stringArray(forKey: LayoutSuggestion.askedKey) ?? []).count == 300, "the memory is bounded")
check(LayoutSuggestion.text(gameName: "Factorio").hasPrefix("Factorio is not asking") && LayoutSuggestion.text(gameName: nil).hasPrefix("This game is not asking"), "the words use the game's name")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/LayoutSuggestion.swift"
"$OUT/t"
rm -rf "$OUT"
