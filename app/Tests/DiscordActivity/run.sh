#!/bin/bash
# What Porthole shows on Discord when the person turned activity on (Sources/Discord/DiscordActivity.swift): "<game> on Porthole", or what they are doing in the app.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
typealias A = DiscordActivity

check(A.cleanName("  Factorio  ") == "Factorio", "spaces are trimmed")
check(A.cleanName("Half\nLife\r\n 2") == "Half Life 2", "line breaks become one space")
check(A.cleanName("   \n ") == nil && A.cleanName("") == nil, "nothing left, nothing shown")
check(A.cleanName(String(repeating: "x", count: 300))?.count == 128, "cut to Discord's limit")

// Which kind
check(A.kind(game: "Firewatch", downloading: ["X"], tab: "settings") == .game("Firewatch"), "a running game comes before everything")
check(A.kind(game: nil, downloading: ["Hades"], tab: "settings") == .downloading("Hades"), "a download comes before the screen")
check(A.kind(game: nil, downloading: ["A", "B"], tab: "library") == .downloading(nil), "several downloads are not named")
check(A.kind(game: "  ", downloading: [], tab: "library") == .browsingLibrary, "a blank game name is not a game")
check(A.kind(game: nil, downloading: [], tab: "library") == .browsingLibrary && A.kind(game: nil, downloading: [], tab: "stores") == .browsingStores, "library and stores")
check(A.kind(game: nil, downloading: [], tab: "settings") == .settings && A.kind(game: nil, downloading: [], tab: "compatibility") == .readingReports, "settings and reports")
check(A.kind(game: nil, downloading: [], tab: "social") == .other, "any other screen")

// The entry
let start = Date(timeIntervalSince1970: 1_700_000_000)
let game = A.activity(for: .game("Firewatch"), since: start)!
check(game["name"] as? String == "Firewatch on Porthole" && game["type"] as? Int == 0 && game["details"] == nil, "a game shows as \"Firewatch on Porthole\"")
check((game["timestamps"] as? [String: Int])?["start"] == 1_700_000_000_000, "started at that time, in milliseconds")
let long = A.activity(for: .game(String(repeating: "g", count: 300)), since: start)!
check((long["name"] as? String)?.count == 128 && (long["name"] as? String)?.hasSuffix(" on Porthole") == true, "a long game name is cut so the whole line fits Discord's limit")
check(A.activity(for: .game("   "), since: start) == nil, "an empty game name is no activity")
let browsing = A.activity(for: .browsingLibrary, since: start)!
check(browsing["name"] as? String == "Porthole" && browsing["details"] as? String == "Browsing their library", "browsing the library")
check(A.activity(for: .settings, since: start)?["details"] as? String == "Adjusting settings", "adjusting settings")
check(A.activity(for: .downloading("Hades"), since: start)?["details"] as? String == "Downloading Hades", "one download is named")
check(A.activity(for: .downloading(nil), since: start)?["details"] as? String == "Downloading games", "several are not")
check(A.activity(for: .browsingStores, since: start)?["details"] as? String == "Browsing the game stores", "the stores")

let on = A.presence(activity: game)
check((on["activities"] as? [[String: Any]])?.count == 1 && on["status"] as? String == "online" && on["afk"] as? Bool == false, "presence with an activity")
check((A.presence(activity: nil)["activities"] as? [Any])?.isEmpty == true, "presence without one clears it")
check(JSONSerialization.isValidJSONObject(["op": 3, "d": on]), "it can be sent as JSON")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$HERE/../../Sources/Discord/DiscordActivity.swift" "$OUT/main.swift" 2>&1 | grep -v "^$" | head -10 || true
"$OUT/t"
