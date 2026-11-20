#!/bin/bash
# Compiles DiscordMessage (with DiscordModels) for the Mac and checks how messages are read, made readable and grouped.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
extension Result { var isSuccessValue: Bool { if case .success = self { return true }; return false } }
func json(_ s: String) -> [String: Any] { (try! JSONSerialization.jsonObject(with: Data(s.utf8))) as! [String: Any] }

let m = DiscordMessage.parse(json("""
{"id":"100","channel_id":"7","type":0,"content":"hi <@2> and <@!3>, see <#9> <:wave:55> <a:dance:56> <@&77>","timestamp":"2026-11-13T20:10:12.123000+00:00","edited_timestamp":null,
 "author":{"id":"1","username":"alex","global_name":"Alex","avatar":"abc"},
 "mentions":[{"id":"2","username":"sam","global_name":"Sam"},{"id":"3","username":"jo"}],
 "attachments":[{"id":"a1","filename":"shot.PNG","url":"https://cdn.example/shot.png","content_type":"image/png"},{"id":"a2","filename":"log.txt","url":"https://cdn.example/log.txt"}],
 "embeds":[{"title":"A page","type":"link"},{"type":"image"}],"sticker_items":[{"id":"s"}]}
"""), channelName: { $0 == "9" ? "general" : nil })!
check(m.content == "hi @Sam and @jo, see #general :wave: :dance: @role", "mentions, channels and emoji read as names")
check(m.author.displayName == "Alex" && m.channelID == "7" && !m.edited, "author, channel, not edited")
check(m.attachments.count == 2 && m.attachments[0].isImage && !m.attachments[1].isImage, "an image attachment is known by its type or extension; a text file is not")
check(m.embeds.count == 1 && m.embeds[0].title == "A page" && m.extras.isEmpty && m.stickers.count == 1, "a link's card and a sticker are drawn; an embed with nothing to draw is dropped")
check(abs(m.date.timeIntervalSince1970 - 1794600612.123) < 1, "the date with fractions of a second is read")
check(DiscordMessage.date("2026-11-13T20:10:12+00:00") != nil, "...and without")

check(DiscordMessage.parse(json(#"{"id":"1","channel_id":"7","type":7,"content":"","timestamp":"2026-11-13T20:10:12+00:00","author":{"id":"1","username":"a"}}"#)) == nil, "a join message is not chat")
check(DiscordMessage.parse(json(#"{"id":"1","type":0}"#)) == nil, "a message without an author or channel is dropped")
let edited = DiscordMessage.parse(json(#"{"id":"1","channel_id":"7","content":"x","timestamp":"2026-11-13T20:10:12+00:00","edited_timestamp":"2026-11-13T20:11:00+00:00","author":{"id":"1","username":"a"}}"#))!
check(edited.edited, "an edited message says so")
let reply = DiscordMessage.parse(json(#"{"id":"2","channel_id":"7","type":19,"content":"yes","timestamp":"2026-11-13T20:10:12+00:00","author":{"id":"1","username":"a"},"referenced_message":{"content":"shall we? <@5>","author":{"id":"4","username":"b","global_name":"Bea"},"mentions":[{"id":"5","username":"c"}]}}"#))!
check(reply.replyTo == "Bea: shall we? @c", "a reply names who it answers and what they said")
check(DiscordMessage.readable("<t:1794600612:R> and <@99>", mentions: [], channelName: { _ in nil }).hasSuffix("and @someone"), "a time code becomes a date and an unknown mention is 'someone'")

func msg(_ id: String, _ who: String, _ t: Double, reply: String? = nil) -> DiscordMessage {
    DiscordMessage(id: id, channelID: "7", author: DiscordUser(id: who, username: who), content: id, date: Date(timeIntervalSince1970: t), edited: false, attachments: [], extras: [], replyTo: reply)
}
let g = DiscordMessageGroup.groups([msg("1", "a", 0), msg("2", "a", 60), msg("3", "b", 90), msg("4", "a", 100), msg("5", "a", 100 + 8 * 60), msg("6", "a", 100 + 8 * 60 + 10, reply: "x")])
check(g.map { $0.messages.map(\.id) } == [["1", "2"], ["3"], ["4"], ["5"], ["6"]], "same person within seven minutes is one block; another person, a long pause or a reply starts a new one")
check(DiscordMessageGroup.groups([]).isEmpty, "no messages, no blocks")
let merged = DiscordMessage.merged([msg("9", "a", 9), msg("10", "a", 10)], [msg("8", "b", 8), msg("10", "c", 11)], cap: 3)
check(merged.map(\.id) == ["8", "9", "10"] && merged[2].author.id == "c", "merged lists are oldest first by id (9 before 10), with one entry per message and the newer one winning")
check(DiscordMessage.merged(merged, [msg("11", "a", 12)], cap: 3).map(\.id) == ["9", "10", "11"], "only the newest few are kept")
check(OutgoingMessage.check("  hello \n") == .success("hello"), "a message is trimmed")
check(OutgoingMessage.check(" \n\t ") == .failure(.empty) && OutgoingMessage.check("") == .failure(.empty), "nothing but spaces is not sent")
check(OutgoingMessage.check(String(repeating: "a", count: 2000)) == .success(String(repeating: "a", count: 2000)), "2000 characters is allowed")
check(OutgoingMessage.check(String(repeating: "a", count: 2013)) == .failure(.tooLong(2013)) && OutgoingMessage.Problem.tooLong(2013).message.contains("13 characters too long"), "more than 2000 says by how much")
check(OutgoingMessage.check(String(repeating: "\u{1F600}", count: 2000)).isSuccessValue, "2000 emoji are 2000 characters")
let n1 = OutgoingMessage.nonce(), n2 = OutgoingMessage.nonce()
check(n1 != n2 && n1.count >= 17 && UInt64(n1) != nil, "a nonce is a long number and differs each time")
print(failed == 0 ? "\nALL PASSED" : "\n\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$OUT/main.swift" "$HERE/../../Sources/Discord/DiscordMessage.swift" "$HERE/../../Sources/Discord/DiscordModels.swift" "$HERE/../../Sources/Discord/DiscordPermissions.swift"
"$OUT/t"
rm -rf "$OUT"
