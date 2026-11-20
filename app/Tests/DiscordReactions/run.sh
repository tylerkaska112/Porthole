#!/bin/bash
# Reactions under a message: reading them, counting adds and removes (also the echo of this account's own), and the way an emoji is named in a request (Sources/Discord/DiscordMessage.swift).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
typealias M = DiscordMessage

let raw: [String: Any] = ["id": "10", "channel_id": "5", "type": 19, "content": "hi", "timestamp": "2026-11-17T10:00:00.000000+00:00",
    "author": ["id": "1", "username": "alex"],
    "message_reference": ["message_id": "9", "channel_id": "5"],
    "reactions": [["emoji": ["id": NSNull(), "name": "👍"], "count": 3, "me": true], ["emoji": ["id": "777", "name": "party", "animated": true], "count": 2, "me": false], ["emoji": ["name": "x"], "count": 0, "me": false]]]
var m = M.parse(raw)!
check(m.referenceID == "9", "the message it answers")
check(m.reactions.count == 2 && m.reactions[0].id == "👍" && m.reactions[0].count == 3 && m.reactions[0].me, "a unicode emoji is read with its count and whether this account used it")
check(m.reactions[1].id == "party:777" && m.reactions[1].customID == "777" && m.reactions[1].animated && m.reactions[1].imageURL?.absoluteString == "https://cdn.discordapp.com/emojis/777.gif?size=48", "a server's emoji is named name:id and has a picture")
check(M.Reaction.key(name: "👍", id: nil) == "👍", "a plain emoji is its own name in a request")

// someone else adds and removes
let thumbs = (name: "👍", id: String?.none, animated: false)
let heart = (name: "❤️", id: String?.none, animated: false)
m.apply(emoji: thumbs, add: true, mine: false)
check(m.reactions[0].count == 4 && m.reactions[0].me, "another person's add raises the count")
m.apply(emoji: heart, add: true, mine: false)
check(m.reactions.count == 3 && m.reactions[2].count == 1 && !m.reactions[2].me, "a new emoji is added at the end")
m.apply(emoji: heart, add: false, mine: false)
check(m.reactions.count == 2, "the last one removed takes the emoji away")

// this account's own press, then Discord's echo
var n = M.parse(raw)!
let on = n.toggle(emoji: heart)
check(on && n.reactions.last?.id == "❤️" && n.reactions.last?.me == true && n.reactions.last?.count == 1, "pressing a new emoji adds it at once")
n.apply(emoji: heart, add: true, mine: true)
check(n.reactions.last?.count == 1, "the echo of my own add changes nothing")
let off = n.toggle(emoji: heart)
check(!off && n.reactions.count == 2, "pressing it again takes it away at once")
n.apply(emoji: heart, add: false, mine: true)
check(n.reactions.count == 2, "the echo of my own removal changes nothing")
let off2 = n.toggle(emoji: thumbs)
check(!off2 && n.reactions[0].count == 2 && !n.reactions[0].me, "pressing one I used takes my vote away and leaves the others'")

// events
check(M.emoji(from: ["id": NSNull(), "name": "🎉"])?.name == "🎉" && M.emoji(from: ["id": "5", "name": "x", "animated": true])?.animated == true, "an emoji is read from an event")
check(M.emoji(from: nil) == nil, "no emoji, none")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$HERE/../../Sources/Discord/DiscordMessage.swift" "$HERE/../../Sources/Discord/DiscordModels.swift" "$HERE/../../Sources/Discord/DiscordPermissions.swift" "$OUT/main.swift" 2>&1 | grep -v "^$" | head -20 || true
"$OUT/t"
