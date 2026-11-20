#!/bin/bash
# Compiles the notification rules (with DiscordMessage and DiscordModels) for the Mac and checks which messages notify and how banners queue.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
func json(_ s: String) -> [String: Any] { (try! JSONSerialization.jsonObject(with: Data(s.utf8))) as! [String: Any] }
func msg(_ extra: String, author: String = "2", guild: String? = "g") -> DiscordMessage {
    let g = guild.map { #""guild_id":"\#($0)","# } ?? ""
    return DiscordMessage.parse(json(#"{"id":"1","channel_id":"c",\#(g)"content":"hey","timestamp":"2026-11-13T20:10:12+00:00","author":{"id":"\#(author)","username":"u\#(author)"}\#(extra)}"#))!
}
let me = "1"
let plain = msg(""), mention = msg(#","mentions":[{"id":"1","username":"me"}]"#), dm = msg("", guild: nil), dmMention = msg(#","mentions":[{"id":"1","username":"me"}]"#, guild: nil)
let reply = msg(#","type":19,"referenced_message":{"content":"x","author":{"id":"1","username":"me"}}"#)
let mine = msg(#","mentions":[{"id":"1","username":"me"}]"#, author: "1")
let everyone = msg(#","mention_everyone":true"#)

check(!DiscordNotifyRule.shouldNotify(plain, me: me, kind: .mentions) && DiscordNotifyRule.shouldNotify(mention, me: me, kind: .mentions), "mentions: only a message that names you")
check(DiscordNotifyRule.shouldNotify(reply, me: me, kind: .mentions), "mentions: an answer to something you wrote counts")
check(!DiscordNotifyRule.shouldNotify(everyone, me: me, kind: .mentions), "mentions: @everyone does not count")
check(!DiscordNotifyRule.shouldNotify(dm, me: me, kind: .mentions) && DiscordNotifyRule.shouldNotify(dmMention, me: me, kind: .mentions), "mentions: a plain direct message does not count, one naming you does")
check(DiscordNotifyRule.shouldNotify(dm, me: me, kind: .direct) && !DiscordNotifyRule.shouldNotify(plain, me: me, kind: .direct) && !DiscordNotifyRule.shouldNotify(mention, me: me, kind: .direct), "direct messages: only outside servers, not even a mention in a server")
check(DiscordNotifyRule.shouldNotify(plain, me: me, kind: .everything) && DiscordNotifyRule.shouldNotify(dm, me: me, kind: .everything), "everything: any message")
check(DiscordNotifyKind.allCases.allSatisfy { !DiscordNotifyRule.shouldNotify(mine, me: me, kind: $0) }, "never for what this account wrote")
check(dm.isDirect && !plain.isDirect && mention.mentions(me) && !plain.mentions(me), "direct and mention flags are read from the message")

func b(_ channel: String, _ text: String, count: Int = 1) -> DiscordBanner {
    DiscordBanner(conversation: DiscordConversation(id: channel, title: "#\(channel)", place: "S"), author: DiscordUser(id: "2", username: "alex", globalName: "Alex"), text: text, count: count)
}
var q = DiscordBannerQueue()
q.push(b("a", "one")); q.push(b("b", "two")); q.push(b("a", "three"))
check(q.waiting.map { $0.conversation.id } == ["a", "b"] && q.waiting[0].count == 2 && q.waiting[0].text == "three" && q.waiting[0].line == "2 new messages", "a second message of a conversation joins its banner, newest text, counted")
q.push(b("c", "x")); q.push(b("d", "y"))
check(q.waiting.map { $0.conversation.id } == ["b", "c", "d"], "only three wait; the oldest waiting one is dropped")
check(q.pop()?.conversation.id == "b" && q.waiting.count == 2, "the oldest is shown first")
q.clear(); check(q.isEmpty && q.pop() == nil, "cleared")
let dmBanner = DiscordBanner(conversation: DiscordConversation(id: "9", title: "Alex", place: nil), author: DiscordUser(id: "2", username: "alex", globalName: "Alex"), text: "hi")
check(dmBanner.headline == "Alex" && b("general", "hi").headline == "Alex in #general", "headlines: a direct message names the person, a server message the channel")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Discord/DiscordNotifyRule.swift" "$HERE/../../Sources/Discord/DiscordMessage.swift" "$HERE/../../Sources/Discord/DiscordModels.swift" "$HERE/../../Sources/Discord/DiscordPermissions.swift"
"$OUT/t"
rm -rf "$OUT"
