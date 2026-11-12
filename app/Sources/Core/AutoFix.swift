// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Reads the log of a run that went wrong and, when it clearly shows a known cause with a known setting that fixes it, says which setting to change.
///
/// This file is only the decision: no screens, no games, nothing is changed here. `AutoFixStore` applies a decision to one game (and can take it back); the tests in
/// app/Tests/AutoFix run these rules against logs people sent in. A rule says which lines of a log must be there (`all`), which one of several (`any`), which must not be
/// (`none`), what the run did at its end, and the one change it makes. A change is small, reversible and only for the one game; a cause that has no safe change here has
/// no rule (it is the engine's to fix, not a setting's).
enum AutoFix {
    /// What a rule changes for a game.
    enum Change: Codable, Equatable {
        /// "AVX and AVX2" on (the program runs AVX instructions; FEX emulates them with 128-bit pairs).
        case avx
        /// The swap file, so the game's memory can spill to storage instead of iOS ending the app.
        case swap(megabytes: Int, coverage: String)
        /// The swap file stays as it is and covers more of the game's memory (the coverage choice: "wide" = 1 MB and up, and overflow).
        case swapCoverage(String)
        /// One line of the game's own madeira.cfg text ("env.MADEIRA_X64_IMAGE_NOCOPY = 1").
        case config(key: String, line: String)
        /// Nothing is changed: the cause is not a setting of the game (the install lacks a capability, say), and the person is told.
        case advice
    }

    /// How the run ended, as far as the app knows (not as far as the log says: a run that iOS ended leaves no last line).
    struct Ending: Equatable {
        /// The app was closed by iOS or crashed while the game ran (the next launch found the session marker).
        var endedUnexpectedly = false
        /// The person pressed Stop / Close while the game was still starting.
        var stoppedByPerson = false
        /// The game's session ended on its own within a few minutes of starting (it quit, or Wine ended it).
        var endedEarly = false
    }

    /// What this device and game are like right now; some rules do not apply to a device or a setup where the change would do nothing or harm.
    struct Context: Equatable {
        var ending = Ending()
        /// Swap the game uses now, in MB (0 = off).
        var swapMB = 0
        /// What the swap file covers now: "" = the classic choice (blocks of 8 MB and up), "blocks", "wide" or "broad".
        var swapCoverage = ""
        /// Free storage, in MB.
        var freeStorageMB = Int.max
        /// Memory of the device, in MB.
        var deviceMemoryMB = 0
        /// The game's own madeira.cfg text now (a rule that adds a line does not add one the game already has).
        var configText = ""
        /// Whether this install may map the large address space the engine reserves (the "Extended Virtual Addressing" capability).
        var largeAddressAllowed = true
    }

    struct Rule: Equatable {
        /// Short and stable: it is kept in the history and in logs, and a game gets each rule once.
        let id: String
        /// What happened, in a few words ("It needs AVX").
        let title: String
        /// Why the change is expected to help, in a sentence a person can read.
        let reason: String
        /// What was done, in a sentence ("AVX and AVX2 are on for this game.").
        let done: String
        var all: [String] = []
        var any: [String] = []
        var none: [String] = []
        /// How often a line has to be there (the memory warning once is normal; it repeated before every game that was ended).
        var atLeast: [String: Int] = [:]
        /// The run has to have ended in this way (either of the two), or nil for any ending.
        var endings: Set<EndingKind>? = nil
        let change: Change
        /// A condition on the device that the change needs (swap is no help with no storage left for it).
        var suits: (Context) -> Bool = { _ in true }

        static func == (a: Rule, b: Rule) -> Bool { a.id == b.id }
    }

    enum EndingKind: Hashable { case unexpected, stopped, early }

    /// Whether the game's text already sets this key (any value: a person's own choice is never overruled).
    static func hasConfigKey(_ text: String, _ key: String) -> Bool {
        text.split(separator: "\n").contains { $0.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } == key }
    }

    /// The rules in use: the built-in ones, with whatever the Hub's list (AutoFixRemote) adds, replaces or switches off.
    struct RuleSet {
        var rules: [Rule]
        /// Every line a rule asks about, once, sorted.
        var needles: [String]
        /// The ids the Hub switched off. A log rule that is off is simply not in `rules`; this also covers the fixes that come from what is known about a game (tested setup,
        /// community settings) and the program repair, which are not log rules.
        var disabled: Set<String>
        init(_ rules: [Rule], disabled: Set<String> = []) {
            self.rules = rules
            self.disabled = disabled
            var set: Set<String> = [AutoFix.stoppedLine]
            set.formUnion(LastRun.needles)
            for r in rules { set.formUnion(r.all); set.formUnion(r.any); set.formUnion(r.none); set.formUnion(r.atLeast.keys) }
            needles = set.sorted()
        }
    }

    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var set: RuleSet
        init(_ set: RuleSet) { self.set = set }
        var value: RuleSet { lock.lock(); defer { lock.unlock() }; return set }
        func replace(_ new: RuleSet) { lock.lock(); set = new; lock.unlock() }
    }
    private static let holder = Holder(RuleSet(builtIn))

    /// The rules in use now.
    static var ruleSet: RuleSet { holder.value }
    static var rules: [Rule] { ruleSet.rules }
    /// Whether the Hub has switched this fix off (any id: a log rule, "tested-setup", "community-settings", "program-moved").
    static func isDisabled(_ id: String) -> Bool { ruleSet.disabled.contains(id) }
    /// Starts using this set (the Hub's list was read), or the built-in one again (nil).
    static func install(_ set: RuleSet?) { holder.replace(set ?? RuleSet(builtIn)) }

    /// The rules that come with the app. Each came from logs that were sent in; its evidence is named in its comment, and app/Tests/AutoFix checks it against them.
    static let builtIn: [Rule] = [
        // Witcher 3 (compat report #139) and Dying Light 2 (#146), iPhone 17 Pro, Porthole 1.2.1: both ended on the first AVX instruction (`c5 ..`, a VEX prefix) with
        // "DISABLEAVX expected" in the log (FEX had AVX off) and `c000001d` as the exit code. Not one of the other 29 logs has that exit code. Crysis 2 Remastered
        // stopped the same way (its entry in GameRecommendations).
        Rule(id: "avx-needed", title: "It needs AVX",
             reason: "The program ran an AVX instruction, which Porthole switches off unless a game asks for it.",
             done: "AVX and AVX2 are on for this game.",
             all: ["DISABLEAVX expected", "UnhandledExceptionFilter code=c000001d"],
             change: .avx),
        // Hogwarts Legacy (compat report #101, ended with c0000017 = no memory), Idleon (problem report #33, 6 GB iPhone, 8 repeats) and FINAL FANTASY RESONANCE (#32): the
        // emulator's JIT pool ran out "while an image was being copied into it". Copying a DLL into the pool is not needed for a DLL of pure x64 code: with the line the
        // engine maps such images where they are (its own description of the line in madeira.cfg's catalog). The phrase is in 4 of the 95 logs read and in no game that
        // ran well. SurrounDead (#162) has it and is rated playable: it still only changes the game when the run ended badly.
        Rule(id: "pool-image-copies", title: "Its memory pool filled up with copies of the game's libraries",
             reason: "The emulator's code pool ran out of room while it copied the game's libraries into it, and libraries made only of x64 code do not have to be copied.",
             done: "The libraries of this game are no longer copied into the pool.",
             all: ["[jit-pool] EXHAUSTED (image"],
             endings: [.unexpected, .stopped, .early],
             change: .config(key: "env.MADEIRA_X64_IMAGE_NOCOPY", line: "env.MADEIRA_X64_IMAGE_NOCOPY = 1"),
             suits: { !hasConfigKey($0.configText, "env.MADEIRA_X64_IMAGE_NOCOPY") }),
        // FINAL FANTASY RESONANCE (problem #32, iPhone 16 Pro Max, Porthole 1.2.1, a 512 MB pool): the game's sound (XAudio2) needs AVRT.dll, whose code was not copied into the pool
        // ("no JIT-pool copy for executable section") because the emulator's own code buffers had taken 322 MB of the pool's tail, so the library failed with c0000017 and then
        // XAudio2 with c0000135. The game already has the line of the rule above (GameFixes), so that rule has nothing left to change. With `pool-low` the code buffers live in a free
        // run below the program's window and the whole pool is left to libraries (upstream Madeira's recommendation for the game, PR 596, was confirmed by a person there). It costs
        // address space and some memory (about 256 MB estimated), so it is offered only after this exact failure, never to every run of the game.
        Rule(id: "pool-code-buffers-low", title: "The memory pool had no room for a library the game needs",
             reason: "The emulator's code buffers filled most of its memory pool, so a Windows library the game needs (its sound library, in the logs seen) could not be copied into it and the game stopped. Giving the code buffers a region of their own leaves the whole pool for libraries.",
             done: "The emulator's code buffers have a memory region of their own for this game.",
             all: ["no JIT-pool copy for executable section", "status=c0000017"],
             endings: [.unexpected, .stopped, .early],
             change: .config(key: "pool-low", line: "pool-low = 1"),
             suits: { !hasConfigKey($0.configText, "pool-low") }),
        // 13 of the 87 logs: "[fex-arena] ... native reserve FAILED kr=3" (the engine could not set aside the address space its emulator lives in). 11 were rated broken,
        // 2 playable, none great, and every one of them was from an install the install check marks "Large address space is not allowed" (the profile lacks Extended
        // Virtual Addressing, or the signing tool dropped it). No setting of the game helps; the install does.
        Rule(id: "address-space-entitlement", title: "This install cannot reserve the memory the emulator needs",
             reason: "The emulator could not set aside the address space it runs in. This copy of Porthole was installed without the \u{201C}Extended Virtual Addressing\u{201D} capability, so many games will not start or close soon after.",
             done: "Nothing was changed. Settings \u{203A} Setup guide shows how to install Porthole with that capability.",
             all: ["native reserve FAILED"],
             endings: [.unexpected, .stopped, .early],
             change: .advice,
             suits: { !$0.largeAddressAllowed }),
        // Unity games that ran out of memory: of the 95 logs read, every one with UnityPlayer.dll loaded and the memory warning twice or more was rated broken (R.E.P.O. #99,
        // Supermarket Simulator #109, CORDURA #116, Oxygen Not Included #149, House Flipper #156, Pumping Simulator #158, Fears to Fathom #173); the two games rated great that logged the
        // same warnings (Devil May Cry 5, Castle Crashers) are not Unity. The cause is documented for Supermarket Simulator (GameFixes): block-compressed textures that the GPU cannot
        // sample are decoded to four to eight times their size. The engine's automatic texture saver drops the top detail level of large textures once the app is near its limit, and
        // it is only on by default in the 32-bit build.
        Rule(id: "unity-texture-saver", title: "A Unity game ran out of memory on its textures",
             reason: "Unity games load hundreds of compressed textures, which many iPhone and iPad GPUs decode to four to eight times their size, and iOS ended Porthole when memory ran out. The engine's texture saver drops the top detail level of large textures once the app is near its limit.",
             done: "The texture saver is on for this game.",
             all: ["Load module UnityPlayer.dll", "[mem-pressure] CRITICAL"],
             atLeast: ["[mem-pressure] CRITICAL": 2],
             endings: [.unexpected, .stopped],
             change: .config(key: "env.MADEIRA_MIP_CLAMP_AUTO", line: "env.MADEIRA_MIP_CLAMP_AUTO = 1"),
             suits: { !hasConfigKey($0.configText, "env.MADEIRA_MIP_CLAMP_AUTO") }),
        // House Flipper (#156, 6 GB iPad: "Memory is almost full", 78 MB free, then gone), Fears to Fathom (#173, 4 GB iPhone) and Pumping Simulator (#158): the memory
        // warning repeated and iOS ended the app. A swap file lets the game's memory go to storage. Only where swap is off (a game that already has swap needs
        // something else) and the storage can hold it. Coverage "wide" (Settings: "1 MB+ and overflow"): the file only helps for the memory it is allowed to take,
        // and the narrower choices leave most of a game's allocations out of it.
        Rule(id: "memory-swap", title: "It ran out of memory",
             reason: "iOS ran short of memory while the game was running, then ended the app. A swap file lets part of the game's memory live on the device's storage.",
             done: "Swap (4 GB) is on for this game.",
             all: ["[mem-pressure] CRITICAL"],
             atLeast: ["[mem-pressure] CRITICAL": 2],
             endings: [.unexpected, .stopped],
             change: .swap(megabytes: 4096, coverage: "wide"),
             suits: { $0.swapMB == 0 && $0.freeStorageMB >= 4096 + 2048 }),
        // Dying Light: The Beast (problem report, 11 GB iPhone 17 Pro, 4 GB swap): killed at 8192 MB with the swap file holding 32 MB. Oxygen Not Included (#149, 4 GB swap, 1.3 GB used),
        // House Flipper (#156, 2 GB swap, 0 used) and Dark Souls II (#180, 4 GB swap, 0.6 GB used) show the same: the swap file is on, but with the classic coverage it only takes
        // blocks of 8 MB and up out of the game's memory, so most of what the game holds never goes to it. "Wide" takes 1 MB and up, and the overflow.
        Rule(id: "memory-swap-coverage", title: "Its swap file was hardly used",
             reason: "iOS ran short of memory while the game ran, then ended the app, and the swap file was on but covered only the largest blocks of memory, so almost none of the game's memory went to it.",
             done: "The swap file now covers memory in blocks of 1 MB and up, and the overflow.",
             all: ["[mem-pressure] CRITICAL"],
             atLeast: ["[mem-pressure] CRITICAL": 2],
             endings: [.unexpected, .stopped],
             change: .swapCoverage("wide"),
             suits: { $0.swapMB > 0 && $0.swapCoverage.isEmpty }),
    ]

    /// Fixes that do not come from a line of the log but from what is known about the game: Madeira's or Porthole's tested setup, and what people who say it works use. They are
    /// named here like rules (they have no lines to look for), so a change is recorded, judged by the next run and taken back like any other.
    static let testedSetupRule = Rule(id: "tested-setup", title: "A tested setup exists for this game",
                                      reason: "The game ended badly, and Madeira or Porthole has a setup that was found to work for it (engine lines and switches).",
                                      done: "The tested setup was applied to this game.", change: .advice)
    static let communityRule = Rule(id: "community-settings", title: "Others have it set differently",
                                    reason: "The game ended badly, and most of the people who say it works great have some settings differently from yours.",
                                    done: "Those settings were applied to this game.", change: .advice)
    static let programMovedRule = Rule(id: "program-moved", title: "Its program was found again",
                                       reason: "The program this game starts was not where it was saved (it was moved, or the path was saved wrongly).",
                                       done: "", change: .advice)
    /// What a change would do, said before it is made ("Turn AVX and AVX2 on for this game."): the question Porthole asks when it finds a fix.
    static func proposal(for change: Change) -> String {
        switch change {
        case .avx: return "Turn AVX and AVX2 on for this game."
        case .swap(let megabytes, _): return "Turn on a \(megabytes % 1024 == 0 ? "\(megabytes / 1024) GB" : "\(megabytes) MB") swap file for this game, so its memory can spill to storage."
        case .swapCoverage: return "Let this game's swap file cover more of its memory."
        case .config(_, let line): return "Add this engine line to this game: \(line)"
        case .advice: return ""
        }
    }

    static func rule(id: String) -> Rule? { rules.first { $0.id == id } ?? [testedSetupRule, communityRule, programMovedRule].first { $0.id == id } }

    // MARK: Reading a log

    /// Which lines of interest a log had, and how many times. Only the needles of the rules are counted, so a 60 MB log costs one pass and a few counters.
    struct Evidence: Equatable {
        var counts: [String: Int] = [:]
        /// The highest frame rate the run's telemetry lines ever showed (0: none, or the game never drew a frame).
        var maxFPS = 0
        /// The first line that held each needle of `LastRun.captureNeedles` (the text of a failure, which a count cannot carry), cut to 400 characters.
        var captures: [String: String] = [:]
        func count(_ needle: String) -> Int { counts[needle] ?? 0 }
        mutating func merge(_ other: Evidence) {
            for (needle, n) in other.counts { counts[needle, default: 0] += n }
            maxFPS = max(maxFPS, other.maxFPS)
            for (needle, line) in other.captures where captures[needle] == nil { captures[needle] = line }
        }
    }

    /// The frames-per-second number of a `[telemetry] 59 fps | ...` line, or nil.
    static func telemetryFPS(_ line: some StringProtocol) -> Int? {
        guard let r = line.range(of: "[telemetry] ") else { return nil }
        var n = 0, digits = 0
        for ch in line[r.upperBound...] {
            guard let d = ch.wholeNumberValue, ch.isASCII else { break }
            n = n * 10 + d; digits += 1
            if digits > 4 { return nil }
        }
        return digits > 0 ? n : nil
    }

    /// The line Porthole writes when the person stops a game that is still starting; it is how a run that ended by the person's hand shows in its log.
    static let stoppedLine = "stop requested while the game was starting"

    /// Every line a rule asks about.
    static var needles: [String] { ruleSet.needles }

    /// Counts the needles in the lines of a log. A line may hold several.
    static func scan<S: Sequence>(lines: S) -> Evidence where S.Element: StringProtocol {
        var e = Evidence()
        let needles = self.needles
        for line in lines {
            for needle in needles where line.contains(needle) {
                e.counts[needle, default: 0] += 1
                if (e.captures[needle] == nil || needle == LastRun.memorySummaryLine), LastRun.captureNeedles.contains(needle) { e.captures[needle] = String(line.prefix(400)) }      // the newest memory line wins: it is written every minute
            }
            if let fps = telemetryFPS(line), fps > e.maxFPS { e.maxFPS = fps }
        }
        return e
    }

    /// The same for a log file, read in pieces (a session log can be tens of MB). Unreadable text is read as what it is, byte for byte, so a stray byte costs one line.
    static func scan(file: URL, chunk: Int = 4 << 20) -> Evidence {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Evidence() }
        defer { try? handle.close() }
        var e = Evidence()
        var tail = Data()
        let newline = UInt8(ascii: "\n")
        while let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            var buffer = tail + data
            // Keep the unfinished last line for the next piece.
            if let last = buffer.lastIndex(of: newline) {
                tail = buffer.suffix(from: buffer.index(after: last))
                buffer = buffer.prefix(through: last)
            } else { tail = buffer; continue }
            let text = String(decoding: buffer, as: UTF8.self)
            e.merge(scan(lines: text.split(separator: "\n", omittingEmptySubsequences: true)))
        }
        if !tail.isEmpty { e.merge(scan(lines: String(decoding: tail, as: UTF8.self).split(separator: "\n"))) }
        return e
    }

    // MARK: Did it work?

    /// Whether a run's log shows the rule's cause again (the evidence only: not how the run ended, not whether the change would still fit).
    static func evidencePresent(_ rule: Rule, _ evidence: Evidence) -> Bool {
        guard rule.all.allSatisfy({ evidence.count($0) >= max(1, rule.atLeast[$0] ?? 1) }) else { return false }
        guard rule.any.isEmpty || rule.any.contains(where: { evidence.count($0) > 0 }) else { return false }
        return rule.none.allSatisfy { evidence.count($0) == 0 }
    }

    enum Outcome: String, Codable { case worked, failed, unclear }

    /// What the run after a change says about it. Worked: the game ran for five minutes and drew frames, and the run did not end badly. Failed: the run ended badly or within two
    /// minutes AND it never drew a frame, or it shows the same cause again before five minutes were up (so the change was no help, and is taken back). Anything else is left
    /// alone, the change stays and nothing is claimed: a game that got further than a quick crash may well have been helped, and with no run from before to compare there is no
    /// telling.
    static func judge(_ rule: Rule, evidence: Evidence, duration: TimeInterval, endedBadly: Bool) -> Outcome {
        if duration >= 300, evidence.maxFPS >= 5, !endedBadly { return .worked }
        if endedBadly || duration < 120, evidence.maxFPS == 0 || (evidencePresent(rule, evidence) && duration < 300) { return .failed }
        return .unclear
    }

    // MARK: Deciding

    /// The rules the evidence and the situation fit, strongest first (the order of `rules`).
    static func matches(_ evidence: Evidence, context: Context) -> [Rule] {
        rules.filter { rule in
            guard rule.all.allSatisfy({ evidence.count($0) >= max(1, rule.atLeast[$0] ?? 1) }) else { return false }
            guard rule.any.isEmpty || rule.any.contains(where: { evidence.count($0) > 0 }) else { return false }
            guard rule.none.allSatisfy({ evidence.count($0) == 0 }) else { return false }
            if let endings = rule.endings {
                var ok = false
                if endings.contains(.unexpected), context.ending.endedUnexpectedly { ok = true }
                if endings.contains(.stopped), context.ending.stoppedByPerson || evidence.count(stoppedLine) > 0 { ok = true }
                if endings.contains(.early), context.ending.endedEarly { ok = true }
                guard ok else { return false }
            }
            return rule.suits(context)
        }
    }

    /// The rule to act on: the first that fits and has not been tried for this game before (`tried` holds the rule ids).
    static func decide(_ evidence: Evidence, context: Context, tried: Set<String>) -> Rule? {
        matches(evidence, context: context).first { !tried.contains($0.id) }
    }
}
