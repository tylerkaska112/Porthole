// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

// What the Reports tab does with its lists: which games a filter keeps, how they are ordered, how many are great, and how a game's reports break down. Foundation only (with
// CompatBadges.swift), so it can be tested on its own (app/Tests/Engine).

enum ReportsScope: String, CaseIterable, Identifiable {
    case mine, all, sent
    var id: String { rawValue }
    var title: String {
        switch self { case .mine: "My games"; case .all: "All games"; case .sent: "My reports" }
    }
}

/// Which verdict a list keeps.
enum ReportsFilter: String, CaseIterable, Identifiable {
    case all, great, playable, broken, untested
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "All"; case .great: "Works great"; case .playable: "Playable"; case .broken: "Doesn't work"; case .untested: "Not yet tested" }
    }
}

enum ReportsOrder: String, CaseIterable, Identifiable {
    case popular, recent, name
    var id: String { rawValue }
    var title: String {
        switch self { case .popular: "Most reports"; case .recent: "Recent"; case .name: "A to Z" }
    }
}

/// One game in a list: from the server's list, or one of the player's own games with the badge the app already holds for it.
struct ReportsItem: Identifiable, Equatable {
    var id: String
    /// The id the server knows the game by (what opens its page).
    var gameID: String
    var title: String
    var reportCount: Int
    /// yyyy-MM-dd, absent for the player's own games (the app only holds their badge).
    var lastReport: String?
    var badge: CompatBadge
    /// Set for a game in the library.
    var libraryID: UUID?

    var verdict: CompatVerdict? { badge.verdict }
    /// In the library with no verdict on this engine yet: worth a report.
    var needsReport: Bool { libraryID != nil && badge.verdict == nil }
}

enum ReportsLogic {
    static func matches(_ item: ReportsItem, _ filter: ReportsFilter) -> Bool {
        switch filter {
        case .all: true
        case .great: item.verdict == .great
        case .playable: item.verdict == .playable
        case .broken: item.verdict == .broken
        case .untested: item.verdict == nil
        }
    }

    /// The items a filter and a search keep, in the chosen order. Ties keep their order from the server (most reports first); a game with no date goes last in "Recent".
    static func visible(_ items: [ReportsItem], filter: ReportsFilter, order: ReportsOrder, query: String) -> [ReportsItem] {
        let text = query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var kept = items.filter { matches($0, filter) }
        if !text.isEmpty { kept = kept.filter { $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(text) } }
        switch order {
        case .popular: return kept.enumerated().sorted { ($0.element.reportCount, $1.offset) > ($1.element.reportCount, $0.offset) }.map(\.element)
        case .recent: return kept.enumerated().sorted { (($0.element.lastReport ?? ""), $1.offset) > (($1.element.lastReport ?? ""), $0.offset) }.map(\.element)
        case .name: return kept.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    struct Summary: Equatable {
        var total = 0, great = 0, playable = 0, broken = 0, untested = 0
        var tested: Int { great + playable + broken }
    }

    static func summary(_ items: [ReportsItem]) -> Summary {
        var s = Summary()
        for item in items {
            s.total += 1
            switch item.verdict { case .great?: s.great += 1; case .playable?: s.playable += 1; case .broken?: s.broken += 1; case nil: s.untested += 1 }
        }
        return s
    }

    // MARK: One game's reports

    /// The part of a report the breakdown needs.
    struct Sample: Equatable {
        var rating: CompatVerdict
        var tags: [String]
        /// False: sent from an earlier version of the game engine, so it does not count toward the verdict.
        var onThisEngine: Bool
        var deviceID: String
    }

    struct Breakdown: Equatable {
        var great = 0, playable = 0, broken = 0
        /// Tag ids with how many reports named them, most named first.
        var tags: [(tag: String, count: Int)] = []
        var earlier = 0

        var total: Int { great + playable + broken }
        func count(_ verdict: CompatVerdict) -> Int { switch verdict { case .great: great; case .playable: playable; case .broken: broken } }
        func fraction(_ verdict: CompatVerdict) -> Double { total == 0 ? 0 : Double(count(verdict)) / Double(total) }

        static func == (a: Breakdown, b: Breakdown) -> Bool {
            a.great == b.great && a.playable == b.playable && a.broken == b.broken && a.earlier == b.earlier && a.tags.map(\.tag) == b.tags.map(\.tag) && a.tags.map(\.count) == b.tags.map(\.count)
        }
    }

    /// Counts the reports from this engine by verdict and by tag; the ones from earlier engines are only counted. `deviceID` keeps one device's reports.
    static func breakdown(_ samples: [Sample], deviceID: String? = nil, topTags: Int = 4) -> Breakdown {
        var out = Breakdown()
        var tags: [String: Int] = [:]
        for s in samples where deviceID == nil || s.deviceID == deviceID {
            guard s.onThisEngine else { out.earlier += 1; continue }
            switch s.rating { case .great: out.great += 1; case .playable: out.playable += 1; case .broken: out.broken += 1 }
            for t in Set(s.tags) { tags[t, default: 0] += 1 }
        }
        out.tags = tags.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(topTags).map { (tag: $0.key, count: $0.value) }
        return out
    }
}
