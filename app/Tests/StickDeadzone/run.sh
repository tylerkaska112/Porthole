#!/bin/bash
# Compiles StickDeadzone (Sources/Core/StickDeadzone.swift) for the Mac and checks the deadzone maths, the drift verdict and the per-controller store.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func near(_ a: Float, _ b: Float, _ e: Float = 0.001) -> Bool { abs(a - b) < e }
typealias Z = StickDeadzone

check(Z.apply(x: 0.07, y: -0.05, zone: 0.12) == (0, 0), "a drift smaller than the deadzone counts as none")
let full = Z.apply(x: 1, y: 0, zone: 0.2)
check(near(full.x, 1) && near(full.y, 0), "a full push is still a full push")
let half = Z.apply(x: 0.6, y: 0, zone: 0.2)
check(near(half.x, 0.5), "beyond the zone the push is stretched back over 0 to 1 (0.6 -> 0.5)")
let diag = Z.apply(x: 0.5, y: 0.5, zone: 0.2)
check(near(diag.x, diag.y) && diag.x > 0, "a diagonal keeps its direction")
check(Z.apply(x: 0.9, y: 0.9, zone: 0.2).x <= 0.8, "the zone is round: a push past the corner never exceeds the edge of the stick")
let none = Z.apply(x: 0.3, y: 0.2, zone: 0)
check(near(none.x, 0.3) && near(none.y, 0.2), "no deadzone leaves the stick alone")
check(Z.apply(x: .nan, y: 0.5, zone: 0.1) == (0, 0), "a broken reading is no push")
let capped = Z.apply(x: 0.4, y: 0, zone: 5)
check(capped == (0, 0), "a deadzone above the maximum is held at the maximum (0.4 is inside 0.5)")

check(Z.verdict(rest: 0.01) == .centred && Z.verdict(rest: 0.08) == .slight && Z.verdict(rest: 0.2) == .drifting, "centred, slight drift and drifting")
check(Z.suggestion(rest: 0.01) == 0, "a centred stick needs no deadzone")
check(Z.suggestion(rest: 0.07) == 0.10, "a stick resting at 7% gets 10%")
check(Z.suggestion(rest: 0.9) == 0.5, "the suggestion never goes past the maximum")

let steady = (0..<30).map { _ in (x: Float(0.06), y: Float(-0.03)) }
let r = Z.rest(samples: steady)
check(r.released && abs(r.distance - 0.0671) < 0.002, "a stick sitting still a bit off the centre is a rest check")
let swept = (0..<30).map { i in (x: Float(sin(Double(i) / 3)) * 0.9, y: Float(0.1)) }
check(!Z.rest(samples: swept).released, "a stick that was moved around is not a rest check")
check(!Z.rest(samples: [(x: 0.9, y: 0)]).released, "a stick held to one side is not let go")
check(Z.rest(samples: []).distance == 0, "no samples: no drift")

let suite = "test.deadzone.\(getpid())"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let store = Z.Store(defaults: defaults)
let key = Z.key(vendor: "Xbox Wireless Controller", category: "Xbox One")
check(key == "Xbox Wireless Controller / Xbox One" && Z.key(vendor: nil, category: " ") == "controller", "a controller's name is its vendor and category")
check(store.setting(for: key).isDefault, "a controller starts with no deadzone")
store.set(.init(left: 0.1, right: 0), for: key)
check(store.setting(for: key).left == 0.1, "a deadzone is kept")
check(Z.Store(defaults: defaults).setting(for: key).left == 0.1, "and read back by a new store (it is saved)")
check(store.apply(key: key, right: false, x: 0.05, y: 0.05) == (0, 0) && store.apply(key: key, right: true, x: 0.05, y: 0.05) == (0.05, 0.05), "it applies to its own stick only")
store.set(.init(left: 9, right: -1), for: key)
check(store.setting(for: key) == .init(left: 0.5, right: 0), "a value outside the range is held to it")
store.set(.init(), for: key)
check(defaults.data(forKey: Z.Store.defaultsKey).flatMap { try? JSONDecoder().decode([String: Z.Setting].self, from: $0) }?.isEmpty == true, "putting it back to none leaves nothing stored")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Core/StickDeadzone.swift"
"$OUT/t"
rm -rf "$OUT"
