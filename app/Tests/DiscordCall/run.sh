#!/bin/bash
# Compiles DiscordCall (with DiscordModels) for the Mac and checks how direct channels and call events are read.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func json(_ s: String) -> [String: Any] { (try! JSONSerialization.jsonObject(with: Data(s.utf8))) as! [String: Any] }

let dm = DiscordDirectChannel.parse(json(#"{"id":"5","type":1,"recipients":[{"id":"2","username":"alex","global_name":"Alex"}]}"#))!
check(!dm.isGroup && dm.recipientIDs == ["2"] && dm.users[0].displayName == "Alex", "a direct message with whole users")
check(dm.title(me: "1", nameOf: { _ in nil }) == "Alex", "...is called by the other person's name")
let ids = DiscordDirectChannel.parse(json(#"{"id":"6","type":1,"recipient_ids":["3"]}"#))!
check(ids.users.isEmpty && ids.recipientIDs == ["3"] && ids.title(me: "1", nameOf: { $0 == "3" ? "Sam" : nil }) == "Sam", "a channel that only has ids is named by looking them up")
check(ids.title(me: "1", nameOf: { _ in nil }) == "Direct message", "...and has a plain name when nobody is known")
let group = DiscordDirectChannel.parse(json(#"{"id":"7","type":3,"name":"Game night","recipient_ids":["2","3","4"]}"#))!
check(group.isGroup && group.title(me: "1", nameOf: { _ in "x" }) == "Game night", "a group chat uses the name it was given")
let unnamed = DiscordDirectChannel.parse(json(#"{"id":"8","type":3,"recipient_ids":["1","2","3","4","9"]}"#))!
check(unnamed.title(me: "1", nameOf: { ["2": "Alex", "3": "Sam", "4": "Jo", "9": "Kit"][$0] }) == "Alex, Sam and 2 more", "an unnamed group lists two names and counts the rest (not me)")
check(DiscordDirectChannel.parse(json(#"{"id":"9","type":0}"#)) == nil && DiscordDirectChannel.parse(json(#"{"type":1}"#)) == nil, "a server channel or one without an id is not a direct channel")
check(DiscordDirectChannel.parse(json(#"{"id":"1","type":3,"name":"","recipient_ids":[]}"#))!.title(me: nil, nameOf: { _ in nil }) == "Group chat", "an empty name is no name")

let call = DiscordCallState.parse(json(#"{"channel_id":"5","message_id":"1","region":"x","ringing":["1"],"voice_states":[{"user_id":"2","channel_id":"5"}]}"#))!
check(call.channelID == "5" && call.rings("1") && !call.rings("2") && call.inCall == ["2"], "a call ringing for me, with the caller in it")
let update = DiscordCallState.parse(json(#"{"channel_id":"5","ringing":[]}"#))!
check(!update.rings("1") && update.inCall.isEmpty, "an update that stops the ringing")
check(DiscordCallState.parse(json(#"{"ringing":["1"]}"#)) == nil, "no channel, no call")
let incoming = DiscordIncomingCall(channelID: "5", title: "Alex", caller: nil, isGroup: false)
check(incoming.headline == "Alex is calling" && incoming.id == "5", "the headline")
check(DiscordIncomingCall(channelID: "6", title: "Game night", caller: nil, isGroup: true).headline == "Game night", "a group is just named")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Discord/DiscordCall.swift" "$HERE/../../Sources/Discord/DiscordModels.swift" "$HERE/../../Sources/Discord/DiscordPermissions.swift"
"$OUT/t"
rm -rf "$OUT"
