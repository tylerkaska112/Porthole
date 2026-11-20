#!/bin/bash
# Reading the posts of a forum from Discord's thread search (Sources/Discord/DiscordForum.swift).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
cat > "$OUT/main.swift" <<'S'
import Foundation
var failed = 0
func check(_ ok: Bool, _ message: String) { print(ok ? "ok:   \(message)" : "FAIL: \(message)"); if !ok { failed += 1 } }

let tags = ["t1": "Bug", "t2": "Idea"]
let reply: [String: Any] = [
    "threads": [
        ["id": "300000000000000001", "name": "Old idea", "owner_id": "5", "applied_tags": ["t2"], "total_message_sent": 4, "last_message_id": "300000000000000001", "flags": 0, "thread_metadata": ["archived": false, "locked": false]],
        ["id": "400000000000000001", "name": "Crash on start", "owner_id": "6", "applied_tags": ["t1", "t2", "gone"], "total_message_sent": 1, "last_message_id": "500000000000000001", "flags": 0, "thread_metadata": ["archived": false, "locked": true]],
        ["id": "100000000000000001", "name": "Read this first", "owner_id": "7", "applied_tags": [], "message_count": 9, "flags": 2, "thread_metadata": ["archived": false]],
    ],
    "first_messages": [
        ["channel_id": "400000000000000001", "content": "  It closes right after the logo.  ", "author": ["id": "6", "username": "kit", "global_name": "Kit"],
         "attachments": [["filename": "shot.PNG", "url": "https://cdn/x.png", "proxy_url": "https://media/x.png"]]],
        ["channel_id": "300000000000000001", "content": "Please add dark mode", "author": ["id": "5", "username": "lee"], "attachments": []],
    ],
]
let posts = DiscordForumPost.posts(fromSearch: reply, tagNames: tags)
check(posts.count == 3, "three posts are read")
check(posts[0].title == "Read this first" && posts[0].pinned, "a pinned post comes first")
check(posts[1].title == "Crash on start" && posts[2].title == "Old idea", "then the most recently active first")
let crash = posts[1]
check(crash.tags == ["Bug", "Idea"], "tag ids become names, an unknown id is dropped")
check(crash.replies == 0 && crash.locked, "one message in all means no replies; locked is read")
check(crash.preview == "It closes right after the logo.", "the preview is the first message, trimmed")
check(crash.thumbnail?.absoluteString == "https://media/x.png", "the first picture is the thumbnail (even with a capital extension)")
check(crash.ownerName == "Kit" && crash.ownerID == "6", "the author's display name")
check(posts[2].ownerName == "lee" && posts[2].replies == 3, "a user name stands in for a missing display name; replies are the messages after the first")
check(posts[0].replies == 8 && posts[0].preview.isEmpty, "message_count is used when total_message_sent is missing; no first message, no preview")
check(posts[1].lastActivity! > posts[2].lastActivity!, "activity comes from the latest message's id")

let active: [[String: Any]] = [["id": "2", "parent_id": "F", "name": "mine"], ["id": "3", "parent_id": "OTHER", "name": "not mine"]]
check(DiscordForumPost.posts(fromThreads: active, forum: "F", tagNames: [:]).map(\.title) == ["mine"], "from a list of active threads only this forum's posts are kept")
check(DiscordForumPost.parse(thread: ["name": "x"], first: nil) == nil, "a thread without an id is nothing")
let long = DiscordForumPost.parse(thread: ["id": "1", "name": "n"], first: ["content": String(repeating: "a", count: 500)])!
check(long.preview.count == 220, "a long first message is cut for the list")

print(failed == 0 ? "ALL OK" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
S
swiftc -swift-version 5 -o "$OUT/t" "$HERE/../../Sources/Discord/DiscordForum.swift" "$HERE/../../Sources/Discord/DiscordProfile.swift" "$HERE/../../Sources/Discord/DiscordModels.swift" "$HERE/../../Sources/Discord/DiscordPermissions.swift" "$OUT/main.swift" 2>&1 | grep -v "^$" | head -20 || true
"$OUT/t"
