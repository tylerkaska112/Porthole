// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// The rules the Hub publishes for the automatic fixes (hub/autofix-admin.js, GET /autofix/rules.json): new rules, rules that replace a built-in one, and a list of rule ids that
/// are switched off. This file only reads and checks that list; it is Foundation only, and app/Tests/AutoFix runs it.
///
/// What a published rule may do is deliberately narrow, because the list comes over the network: turn AVX on, set a swap file of 512 MB to 8 GB, add one `env.NAME = value` line
/// of plain characters to a game's own settings, widen what an existing swap file covers, or only explain. A rule that asks for anything else, or is malformed in any way, is left out and the others are used. A
/// document that is not the schema this app knows is not used at all.
enum AutoFixRemote {
    static let schema = 1

    struct Document: Decodable {
        var schema: Int
        var disabled: [String]?
        var rules: [Raw]?
    }

    struct Raw: Decodable {
        var id: String
        var title: String
        var reason: String
        var done: String
        var all: [String]?
        var any: [String]?
        var none: [String]?
        var atLeast: [String: Int]?
        var endings: [String]?
        var minBuild: Int?
        var maxBuild: Int?
        var change: Change
        var suits: Suits?

        struct Change: Decodable {
            var kind: String
            var megabytes: Int?
            var coverage: String?
            var key: String?
            var line: String?
        }
        struct Suits: Decodable {
            var swapOff: Bool?
            var minFreeStorageMB: Int?
            var keyUnset: String?
            var largeAddressDenied: Bool?
            var swapOn: Bool?
            var coverageClassic: Bool?
        }
    }

    /// What reading a document gave.
    struct Result {
        var set: AutoFix.RuleSet
        /// Rules of the document that were used, left out (with the reason), and the ids switched off.
        var used: [String] = []
        var rejected: [String] = []
        var disabled: [String] = []
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private static let idPattern = "^[a-z0-9][a-z0-9-]{0,63}$"

    /// Reads a document: the built-in rules (unless switched off or replaced) followed by the document's own, for an app of this build number. nil if it is not a document of this
    /// schema; a rule that does not pass the checks is skipped, not the whole document.
    static func read(_ data: Data, builtIn: [AutoFix.Rule], build: Int) -> Result? {
        guard data.count <= 64 * 1024, let doc = try? JSONDecoder().decode(Document.self, from: data), doc.schema == schema else { return nil }
        let off = Set((doc.disabled ?? []).prefix(200).filter { matches($0, idPattern) })
        var rejected: [String] = []
        var remote: [AutoFix.Rule] = []
        var seen = Set<String>()
        for raw in (doc.rules ?? []).prefix(200) {
            switch rule(from: raw) {
            case .failure(let why): rejected.append("\(raw.id): \(why)")
            case .success(let r):
                guard seen.insert(r.id).inserted else { rejected.append("\(raw.id): used twice"); continue }
                if let lo = raw.minBuild, build < lo { continue }
                if let hi = raw.maxBuild, build > hi { continue }
                remote.append(r)
            }
        }
        let replaced = Set(remote.map(\.id))
        var rules: [AutoFix.Rule] = []
        for b in builtIn where !off.contains(b.id) {
            if let r = remote.first(where: { $0.id == b.id }) { rules.append(r) } else if !replaced.contains(b.id) { rules.append(b) }
        }
        for r in remote where !off.contains(r.id) && !builtIn.contains(where: { $0.id == r.id }) { rules.append(r) }
        return Result(set: AutoFix.RuleSet(rules, disabled: off), used: remote.map(\.id).filter { !off.contains($0) }, rejected: rejected, disabled: off.sorted())
    }

    /// One published rule, checked and turned into a rule, or why not.
    static func rule(from raw: Raw) -> Swift.Result<AutoFix.Rule, Failure> {
        guard matches(raw.id, idPattern) else { return .failure(Failure("the id is not lower case letters, digits and dashes")) }
        for text in [raw.title, raw.reason, raw.done] where text.isEmpty || text.count > 400 { return .failure(Failure("a text is empty or longer than 400 characters")) }
        let all = raw.all ?? [], any = raw.any ?? [], none = raw.none ?? [], atLeast = raw.atLeast ?? [:]
        let lines = all + any + none + Array(atLeast.keys)
        guard !lines.isEmpty, lines.count <= 16, lines.allSatisfy({ (6...200).contains($0.count) }) else { return .failure(Failure("the lines to look for are missing, too many, or not 6 to 200 characters")) }
        guard atLeast.values.allSatisfy({ (1...1000).contains($0) }) else { return .failure(Failure("a count is out of range")) }
        var endings: Set<AutoFix.EndingKind>?
        if let names = raw.endings {
            var set = Set<AutoFix.EndingKind>()
            for name in names {
                switch name {
                case "unexpected": set.insert(.unexpected)
                case "stopped": set.insert(.stopped)
                case "early": set.insert(.early)
                default: return .failure(Failure("unknown ending \(name)"))
                }
            }
            endings = set
        }
        var suits = raw.suits ?? Raw.Suits()
        let change: AutoFix.Change
        switch raw.change.kind {
        case "avx": change = .avx
        case "advice": change = .advice
        case "swap":
            guard let mb = raw.change.megabytes, (512...8192).contains(mb) else { return .failure(Failure("a swap file must be 512 to 8192 MB")) }
            let coverage = raw.change.coverage ?? "wide"
            guard ["", "blocks", "wide", "broad"].contains(coverage) else { return .failure(Failure("unknown swap coverage")) }
            change = .swap(megabytes: mb, coverage: coverage)
            if suits.swapOff == nil { suits.swapOff = true }
            if suits.minFreeStorageMB == nil { suits.minFreeStorageMB = mb + 2048 }
        case "swapCoverage":
            guard let coverage = raw.change.coverage, ["blocks", "wide", "broad"].contains(coverage) else { return .failure(Failure("a coverage change names blocks, wide or broad")) }
            change = .swapCoverage(coverage)
            if suits.swapOn == nil { suits.swapOn = true }                 // it widens a swap file that exists ...
            if suits.coverageClassic == nil { suits.coverageClassic = true }   // ... and has the classic coverage (the default), never one the person chose
        case "config":
            guard let key = raw.change.key, let line = raw.change.line, matches(key, "^env\\.[A-Z0-9_]{3,60}$"), line.hasPrefix(key + " = "),
                  matches(String(line.dropFirst(key.count + 3)), "^[A-Za-z0-9_.;:,+-]{0,60}$") else { return .failure(Failure("a config change must be one plain line \"env.NAME = value\"")) }
            change = .config(key: key, line: line)
            if suits.keyUnset == nil { suits.keyUnset = key }      // a rule never overrules a line the person or a known fix already set
        default: return .failure(Failure("unknown kind \(raw.change.kind)"))
        }
        if let key = suits.keyUnset, !matches(key, "^env\\.[A-Z0-9_]{3,60}$") { return .failure(Failure("keyUnset is not an env.NAME key")) }
        if let free = suits.minFreeStorageMB, !(0...200_000).contains(free) { return .failure(Failure("minFreeStorageMB is out of range")) }
        let swapOff = suits.swapOff == true, minFree = suits.minFreeStorageMB, keyUnset = suits.keyUnset, deniedOnly = suits.largeAddressDenied == true
        let swapOn = suits.swapOn == true, classic = suits.coverageClassic == true
        return .success(AutoFix.Rule(id: raw.id, title: raw.title, reason: raw.reason, done: raw.done, all: all, any: any, none: none, atLeast: atLeast, endings: endings, change: change,
                                     suits: { ctx in
            (!swapOff || ctx.swapMB == 0) && (!swapOn || ctx.swapMB > 0) && (!classic || ctx.swapCoverage.isEmpty) && (minFree.map { ctx.freeStorageMB >= $0 } ?? true) && (keyUnset.map { !AutoFix.hasConfigKey(ctx.configText, $0) } ?? true) && (!deniedOnly || !ctx.largeAddressAllowed)
        }))
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }
}
