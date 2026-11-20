#!/bin/bash
# What a profile card is made from: Discord's profile reply, an account's age from its id, and the order of conversations (Sources/Discord/DiscordProfile.swift).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

// The snowflake of Discord's own documentation example is 175928847299117063: made on 2016-04-30 11:18:25 UTC.
let made = DiscordSnowflake.date("175928847299117063")!
let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
check(f.string(from: made) == "2016-04-30 11:18:25", "an account's age is read from its id (the documented example)")
check(DiscordSnowflake.date("junk") == nil && DiscordSnowflake.date("0") == nil, "a bad id gives no date")
check(DiscordSnowflake.isLater("200000000000000000", than: "199999999999999999"), "a later id is later")
check(DiscordSnowflake.isLater("1000000000000000000", than: "999999999999999999"), "a longer id is later")
check(!DiscordSnowflake.isLater("5", than: "5") && !DiscordSnowflake.isLater(nil, than: "5") && DiscordSnowflake.isLater("5", than: nil), "equal or missing ids: only a real id beats none")

let reply: [String: Any] = [
    "user": ["id": "175928847299117063", "username": "alex", "global_name": "Alex", "avatar": "abc", "banner": "ban123", "accent_color": 3447003],
    "user_profile": ["bio": "  I build factories.\n", "pronouns": "they/them"],
    "mutual_guilds": [["id": "g1", "nick": NSNull()], ["id": "g2"]],
    "mutual_friends_count": 3,
]
let p = DiscordProfile.parse(reply)!
check(p.user.displayName == "Alex" && p.user.id == "175928847299117063", "name and id")
check(p.bio == "I build factories." && p.pronouns == "they/them", "bio and pronouns, trimmed")
check(p.bannerURL?.absoluteString == "https://cdn.discordapp.com/banners/175928847299117063/ban123.png?size=480", "banner address")
check(p.accent == 3447003, "the card colour")
check(p.mutualServerIDs == ["g1", "g2"] && p.mutualFriendCount == 3, "shared servers and friends")
check(p.createdAt != nil, "the account's age is filled in")
let bare = DiscordProfile.parse(["user": ["id": "5", "username": "x"]])!
check(bare.bio.isEmpty && bare.pronouns.isEmpty && bare.bannerURL == nil && bare.accent == nil && bare.mutualServerIDs.isEmpty && bare.mutualFriendCount == 0, "a bare reply leaves everything empty")
check(DiscordProfile.parse(["user_profile": ["bio": "x"]]) == nil, "no user, no card")

// Conversations
let dm = DiscordDirectChannel.parse(["id": "9", "type": 1, "recipients": [["id": "5", "username": "x"]], "last_message_id": "1234"])!
check(dm.lastMessageID == "1234" && !dm.isGroup, "a direct message keeps its latest message id")
check(DiscordDirectChannel.parse(["id": "9", "type": 0]) == nil, "a server channel is not a conversation")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$HERE/../../Sources/Discord/DiscordProfile.swift" "$HERE/../../Sources/Discord/DiscordCall.swift" "$HERE/../../Sources/Discord/DiscordModels.swift" "$HERE/../../Sources/Discord/DiscordPermissions.swift" "$OUT/main.swift" 2>&1 | grep -v "^$" | head -20 || true
"$OUT/t"
