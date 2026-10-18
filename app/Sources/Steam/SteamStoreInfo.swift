// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// What Steam publishes about a game without any sign-in: the review summary and the Steam Deck rating from the store, and the game's news (patch notes) from the Web API's news
// feed. Only the game's number is sent; nothing about the person. This file only reads the answers; SteamInfoStore asks.
import Foundation

struct SteamReviewSummary: Codable, Equatable {
    /// Steam's own words, "Overwhelmingly Positive", "Mixed" and so on.
    var text: String
    /// 1 (overwhelmingly negative) to 9 (overwhelmingly positive); 5 is mixed.
    var score: Int
    var positive: Int
    var total: Int
    /// Share of positive reviews, 0 to 100.
    var percent: Int { total > 0 ? Int((Double(positive) / Double(total) * 100).rounded()) : 0 }
}

enum SteamDeckStatus: Int, Codable {
    case unknown = 0, unsupported = 1, playable = 2, verified = 3
    var title: String {
        switch self { case .verified: "Deck Verified"; case .playable: "Deck Playable"; case .unsupported: "Deck Unsupported"; case .unknown: "Deck not rated" }
    }
}

struct SteamNewsItem: Identifiable, Equatable {
    var id: String
    var title: String
    var url: URL?
    var date: Date
    var summary: String
    var source: String
}

enum SteamStoreInfoParser {
    /// `appreviews/<app>?json=1&num_per_page=0`. Nil when the game has no reviews.
    static func reviews(_ data: Data) -> SteamReviewSummary? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], SteamJSON.int(root["success"]) == 1,
              let q = root["query_summary"] as? [String: Any], let total = SteamJSON.int(q["total_reviews"]), total > 0,
              let text = SteamJSON.string(q["review_score_desc"]), !text.isEmpty else { return nil }
        return SteamReviewSummary(text: text, score: SteamJSON.int(q["review_score"]) ?? 0, positive: SteamJSON.int(q["total_positive"]) ?? 0, total: total)
    }

    /// `saleaction/ajaxgetdeckappcompatibilityreport?nAppID=<app>`: `resolved_category` is 0 unknown, 1 unsupported, 2 playable, 3 verified.
    static func deck(_ data: Data) -> SteamDeckStatus {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], SteamJSON.int(root["success"]) == 1,
              let results = root["results"] as? [String: Any], let category = SteamJSON.int(results["resolved_category"]) else { return .unknown }
        return SteamDeckStatus(rawValue: category) ?? .unknown
    }

    /// `ISteamNews/GetNewsForApp`, newest first.
    static func news(_ data: Data) -> [SteamNewsItem] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = (root["appnews"] as? [String: Any])?["newsitems"] as? [[String: Any]] else { return [] }
        return items.compactMap { node in
            guard let id = SteamJSON.string(node["gid"]), let title = SteamJSON.string(node["title"]), !title.isEmpty, let seconds = SteamJSON.double(node["date"]) else { return nil }
            let url = SteamJSON.string(node["url"]).flatMap { $0.contains(" ") ? $0.replacingOccurrences(of: " ", with: "%20") : $0 }.flatMap(URL.init(string:))
            return SteamNewsItem(id: id, title: plain(title), url: url, date: Date(timeIntervalSince1970: seconds), summary: summary(SteamJSON.string(node["contents"]) ?? "", limit: 320),
                                 source: SteamJSON.string(node["feedlabel"]) ?? "")
        }.sorted { $0.date > $1.date }
    }

    /// Text only: tags, Steam's [bbcode] and image placeholders removed, the common HTML entities turned back into characters, spaces and lines folded.
    static func plain(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\{STEAM_CLAN_IMAGE\\}\\S*", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[/?[A-Za-z0-9*]+(=[^\\]]*)?\\]", with: " ", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summary(_ text: String, limit: Int) -> String {
        let s = plain(text)
        guard s.count > limit else { return s }
        let cut = s.prefix(limit)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "\u{2026}"
    }
}
