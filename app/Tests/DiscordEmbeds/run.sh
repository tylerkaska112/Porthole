#!/bin/bash
# Cards, stickers and day lines in a chat (Sources/Discord/DiscordMessage.swift).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }
typealias E = DiscordMessage.Embed

// A rich card
let rich = E.parse(["type": "rich", "title": " Patch 1.4 ", "description": "Fixes <#9> and **more**", "color": 5814783, "provider": ["name": "Porthole"], "author": ["name": "Alex"],
                    "footer": ["text": "released today"], "image": ["url": "https://cdn/a.png", "proxy_url": "https://media/a.png"], "thumbnail": ["url": "https://cdn/t.png"],
                    "fields": [["name": "Fixed", "value": "Menu", "inline": true], ["name": "", "value": "no name"], ["name": "Added", "value": "Forums", "inline": false]]], index: 2)!
check(rich.id == "e2" && rich.title == "Patch 1.4" && rich.provider == "Porthole" && rich.author == "Alex" && rich.footer == "released today", "text parts, trimmed")
check(rich.description == "Fixes #channel and **more**", "the text is made readable")
check(rich.colour == 5814783 && rich.imageURL?.absoluteString == "https://media/a.png" && rich.thumbnailURL?.absoluteString == "https://cdn/t.png", "colour; the proxied picture is preferred")
check(rich.fields.count == 2 && rich.fields[0].inline && !rich.fields[1].inline, "a field without a name is dropped")

// A link that is only a picture keeps its picture in the thumbnail
let pic = E.parse(["type": "image", "url": "https://x/y.png", "thumbnail": ["url": "https://x/y.png"]], index: 0)!
check(pic.imageURL != nil && pic.thumbnailURL == nil, "an image link is drawn as an image")
let gif = E.parse(["type": "gifv", "thumbnail": ["proxy_url": "https://t/g.png"], "video": ["url": "https://t/g.mp4"]], index: 1)!
check(gif.isAnimated && gif.imageURL?.absoluteString == "https://t/g.png", "a gif is drawn as its still and marked as moving")
check(E.parse(["type": "image"], index: 0) == nil && E.parse([:], index: 0) == nil, "an embed with nothing to draw is nothing")

// Stickers
check(DiscordMessage.Sticker.make(id: "5", name: "wave", format: 1)?.url.absoluteString == "https://media.discordapp.net/stickers/5.png?size=160", "a PNG sticker")
check(DiscordMessage.Sticker.make(id: "5", name: "w", format: 2) != nil, "an APNG sticker shows its first frame")
check(DiscordMessage.Sticker.make(id: "5", name: "w", format: 4)?.url.absoluteString == "https://media.discordapp.net/stickers/5.gif?size=160", "a GIF sticker")
check(DiscordMessage.Sticker.make(id: "5", name: "w", format: 3) == nil, "a Lottie sticker cannot be drawn")
let withLottie = DiscordMessage.parse(["id": "1", "channel_id": "2", "type": 0, "content": "", "timestamp": "2026-11-17T10:00:00+00:00", "author": ["id": "1", "username": "a"],
                                       "sticker_items": [["id": "7", "name": "dance", "format_type": 3], ["id": "8", "name": "hi", "format_type": 1]]])!
check(withLottie.extras == ["Sticker: dance"] && withLottie.stickers.count == 1, "a Lottie sticker is named, a picture one is drawn")

// Day lines (a fixed calendar and clock so the test does not depend on today)
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
let now = Date(timeIntervalSince1970: 1_794_700_800)       // 2026-11-15 00:00:00 UTC (a Sunday)
func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
check(DiscordMessageGroup.dayTitle(now.addingTimeInterval(3600), now: now, calendar: cal) == "Today", "today")
check(DiscordMessageGroup.dayTitle(ago(1), now: now, calendar: cal) == "Yesterday", "yesterday (an hour before midnight)")
check(DiscordMessageGroup.dayTitle(ago(24 * 3 + 5), now: now, calendar: cal).lowercased().hasPrefix("wed"), "the weekday within a week (3 days 5 hours before Sunday midnight is a Wednesday)")
check(DiscordMessageGroup.dayTitle(ago(24 * 40), now: now, calendar: cal).contains("2026") == false && DiscordMessageGroup.dayTitle(ago(24 * 40), now: now, calendar: cal).count > 5, "an older date this year has no year")
check(DiscordMessageGroup.dayTitle(ago(24 * 400), now: now, calendar: cal).contains("2025"), "an older year has it")
func group(_ t: Date) -> DiscordMessageGroup {
    DiscordMessageGroup(messages: [DiscordMessage(id: "1", channelID: "2", author: DiscordUser(id: "1", username: "a"), content: "x", date: t, edited: false, attachments: [], extras: [], replyTo: nil)])
}
check(DiscordMessageGroup.startsNewDay(group(now), after: nil, calendar: cal), "the first group has a day line")
check(!DiscordMessageGroup.startsNewDay(group(now.addingTimeInterval(7200)), after: group(now.addingTimeInterval(3600)), calendar: cal), "two groups of one day have none between them")
check(DiscordMessageGroup.startsNewDay(group(now), after: group(ago(2)), calendar: cal), "a new day does")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$HERE/../../Sources/Discord/DiscordMessage.swift" "$HERE/../../Sources/Discord/DiscordModels.swift" "$HERE/../../Sources/Discord/DiscordPermissions.swift" "$OUT/main.swift" 2>&1 | grep -v "^$" | head -20 || true
"$OUT/t"
