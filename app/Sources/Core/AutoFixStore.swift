// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Applies what `AutoFix` decides to a game, keeps a record of every change (so it can be undone and is never made twice) and tells the person.
///
/// When it looks: when a game session ends (the log of this run), and when the app opens after a run in which a game was started (the log the app rotated aside), so a game
/// that took the app down is read too. A fix changes one setting of one game, the same setting the game's page has; it never touches anything app-wide, and Undo puts the old
/// value back. Off with the switch in Settings > Fixing problems.
///
/// By default it only ASKS: a fix it finds is kept as a proposal (Entry.state "proposed"), Home shows it with Apply, and nothing about the game changes until the person
/// says so. Saying no ("declined") leaves the game as it is and the same fix is not offered again; Settings > Fixing problems can still apply it. The switch "Ask me
/// before changing a game" (on by default) can be turned off for the old behaviour: the change is made at once and shown with Undo.
@MainActor
final class AutoFixStore: ObservableObject {
    static let shared = AutoFixStore()
    static let enabledKey = "f4.autofix"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static let askKey = "f4.autofixAsk"
    static var asksFirst: Bool { UserDefaults.standard.object(forKey: askKey) as? Bool ?? true }

    /// The old value of one setting: `before` is nil when the game had no value of its own.
    struct Undo: Codable, Equatable {
        var key: String        // engine.avx, settings.swapMB, settings.swapCoverage
        var before: String?
    }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var gameID: UUID
        var gameName: String
        var ruleID: String
        var title: String
        var reason: String
        var done: String
        var at: Date
        var build: String
        var undo: [Undo]
        var undone = false
        /// The person saw or dismissed the notice.
        var seen = false
        /// Nothing was changed: the notice only explains (there is nothing to undo).
        var adviceOnly: Bool?
        /// The game was started again after the change (the next run will be judged).
        var tryStarted: Bool?
        /// What that run showed: "worked", "failed" (the change was taken back) or "unclear" (kept, nothing claimed).
        var outcome: String?
        var outcomeNote: String?
        var outcomeSeen: Bool?
        /// nil = the change was made. "proposed" = found, waiting for the person's answer (nothing was changed). "declined" = the person said no (nothing was changed).
        var state: String?
    }

    /// The last game session that has not been read yet.
    private struct Session: Codable {
        var gameID: UUID
        var gameName: String
        var started: Date
        var evaluated = false
        /// A change made earlier for this game that this run is the first try of.
        var judging: UUID?
    }

    private struct Saved: Codable {
        var entries: [Entry] = []
        var session: Session?
    }

    @Published private(set) var entries: [Entry] = []
    private var session: Session?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("f4-autofix.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            entries = saved.entries
            session = saved.session
        }
    }

    private func persist() {
        // The newest 60 changes are enough; a game's "tried" list is read from them.
        // The newest 200 are kept, and a suggestion or a "no" is never dropped to make room: a game's "tried" list is read from them, and a fix the person declined must not come back.
        while entries.count > 200, let i = entries.firstIndex(where: { $0.state == nil }) { entries.remove(at: i) }
        guard let data = try? JSONEncoder().encode(Saved(entries: entries, session: session)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The change the person has not seen yet (Home shows it as a notice), newest first.
    var notice: Entry? { entries.last { !$0.seen && !$0.undone && $0.state == nil } }
    /// A fix that was found and is waiting for a yes or no (Home asks about it).
    var proposal: Entry? { entries.last { $0.state == "proposed" } }
    /// What the run after a change showed, once, for a change that worked or was taken back.
    var outcomeNotice: Entry? { entries.last { ($0.outcome == "worked" || $0.outcome == "failed") && $0.outcomeSeen != true } }

    func tried(_ game: Game) -> Set<String> { Set(entries.filter { $0.gameID == game.id }.map(\.ruleID)) }

    // MARK: When to look

    /// A game session started: remember which, so the app can read its log when the session is over, even if the app never gets to say so itself.
    func sessionBegan(_ game: Game) {
        guard game.installer != true, game.inDesktop != true else { return }
        var next = Session(gameID: game.id, gameName: game.name, started: Date())
        // The first start after a change made for this game is the change's test.
        if let i = entries.lastIndex(where: { $0.gameID == game.id && $0.state == nil && !$0.undone && $0.adviceOnly != true && $0.outcome == nil && $0.tryStarted != true }) {
            entries[i].tryStarted = true
            next.judging = entries[i].id
        }
        session = next
        persist()
    }

    /// The session of this run ended and the app is still here: read this run's log.
    func sessionEnded(_ game: Game) {
        guard var s = session, s.gameID == game.id, !s.evaluated else { return }
        s.evaluated = true
        session = s
        persist()
        // A game that is over within three minutes of starting never got going (the usual session is longer).
        let duration = Date().timeIntervalSince(s.started)
        evaluate(game: game, log: LogStore.shared.logFileURL, unexpectedly: false, early: duration < 180, duration: duration, judging: s.judging)
    }

    /// The app opened: if the run before it started a game that nothing has read yet (the app was ended, closed by the person, or crashed), read the log that run left.
    func evaluateAfterLaunch() {
        guard var s = session, !s.evaluated else { return }
        s.evaluated = true
        session = s
        persist()
        guard let game = AppModel.shared.games.first(where: { $0.id == s.gameID }) else { return }
        _ = LogStore.shared.logFileURL        // rotates the finished run's log to madeira-log.prev.txt (once per launch), as CrashEvidence does
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let previous = docs.appendingPathComponent("madeira-log.prev.txt")
        // The log has to be of a run that began the session (a newer run without a game would be some other run's).
        var log = previous
        var modified = (try? previous.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if modified.map({ $0 < s.started }) ?? true {
            // The app was opened again before this one was read, so madeira-log.prev.txt is a later, shorter run. The run's own session log is still there (Documents/logs keeps
            // the last forty, named after the game's program): the newest one of this game written since the session began.
            guard let own = Self.sessionLog(for: game, since: s.started) else { return }
            log = own.url; modified = own.modified
            LogStore.shared.log("[autofix] \(game.name): the previous run's log was replaced; reading its session log \(own.url.lastPathComponent)")
        }
        guard let modified else { return }
        let unexpectedly = CompatStore.shared.endedUnexpectedly != nil
        evaluate(game: game, log: log, unexpectedly: unexpectedly, duration: modified.timeIntervalSince(s.started), judging: s.judging)
    }

    /// The newest session log of this game (Documents/logs, named after its program) that was written to since `since`.
    private static func sessionLog(for game: Game, since: Date) -> (url: URL, modified: Date)? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("logs", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "txt" }
            .map { (url: $0, modified: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .filter { $0.modified >= since }
        let keys = CompatLogPicker.keys(gameName: game.name, exe: game.exe)
        return files.filter { CompatLogPicker.nameMatches($0.url.lastPathComponent, keys: keys) }.max { $0.modified < $1.modified }
    }

    // MARK: Reading and applying

    private func evaluate(game: Game, log: URL, unexpectedly: Bool, early: Bool = false, duration: TimeInterval, judging: UUID?) {
        let storage = Self.freeStorageMB()
        let settings = LaunchSettings.resolve(for: game)
        var context = AutoFix.Context(ending: .init(endedUnexpectedly: unexpectedly, endedEarly: early), swapMB: settings.swapMB, swapCoverage: settings.swapCoverage, freeStorageMB: storage,
                                      deviceMemoryMB: Int(ProcessInfo.processInfo.physicalMemory >> 20), configText: game.engine?.config ?? "",
                                      largeAddressAllowed: InstallCheck.largeAddressSpaceAllowed)
        // A line the game already gets from its known fixes (GameFixes) counts as set.
        if let fix = GameFixes.fix(forSteamAppID: game.dockAppID ?? game.steamAppID), !fix.configLines.isEmpty { context.configText += "\n" + fix.configLines.joined(separator: "\n") }
        let id = game.id
        Task.detached(priority: .utility) {
            let evidence = AutoFix.scan(file: log)
            await MainActor.run {
                // What the run says about itself goes on the game's page, whatever the switch for automatic fixes says.
                let end: LastRun.End = unexpectedly ? .crashed : (evidence.count(AutoFix.stoppedLine) > 0 ? .stopped : (early ? .early : .normal))
                let minutes = Int(duration / 60)
                let said = LastRun.words(evidence: evidence, end: end, minutes: minutes, matched: AutoFix.matches(evidence, context: context), swapMB: context.swapMB, swapCoverage: context.swapCoverage, installNote: InstallCheck.memoryNote)
                LastRunStore.shared.record(LastRun.Summary(gameID: id, gameName: game.name, at: Date(), minutes: minutes, end: end, headline: said.headline, details: said.details, bestFPS: evidence.maxFPS,
                                                         docs: end == .normal ? nil : DocsDiagnosis.matches(evidence).map(\.id)))
                guard Self.enabled else { return }
                if let judging { AutoFixStore.shared.judge(entryID: judging, evidence: evidence, duration: duration, endedBadly: unexpectedly || early || evidence.count(AutoFix.stoppedLine) > 0) }
                guard let rule = AutoFix.decide(evidence, context: context, tried: AutoFixStore.shared.triedNow(id)) else {
                    LogStore.shared.log("[autofix] \(game.name): no known cause found in the log")
                    // Only a real crash or a stop by the engine counts here: a short run alone may be a person closing the game.
                    AutoFixStore.shared.trySources(gameID: id, endedBadly: unexpectedly || evidence.count(AutoFix.stoppedLine) > 0)
                    return
                }
                AutoFixStore.shared.offerOrApply(rule, to: id)
            }
        }
    }

    /// The first run after a change: did it help? A change that did not is put back (the game ended badly or never drew a frame, so the setting was no use and the
    /// person's settings stay as they were); one that did is said so, once. Every verdict is written to the log, so a report carries it.
    private func judge(entryID: UUID, evidence: AutoFix.Evidence, duration: TimeInterval, endedBadly: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == entryID }), entries[i].outcome == nil, !entries[i].undone, entries[i].state == nil,
              let rule = AutoFix.rule(id: entries[i].ruleID) else { return }
        let outcome = AutoFix.judge(rule, evidence: evidence, duration: duration, endedBadly: endedBadly)
        let minutes = Int(duration / 60)
        entries[i].outcome = outcome.rawValue
        entries[i].outcomeNote = "ran \(minutes) min, best \(evidence.maxFPS) fps\(endedBadly ? ", ended badly" : "")"
        entries[i].outcomeSeen = outcome == .unclear ? true : false
        LogStore.shared.log("[autofix] outcome \(entries[i].gameName) \(rule.id): \(outcome.rawValue) (\(entries[i].outcomeNote ?? ""))")
        let entry = entries[i]
        persist()
        if outcome == .failed { undo(entry); if let j = entries.firstIndex(where: { $0.id == entryID }) { entries[j].outcome = outcome.rawValue; entries[j].outcomeNote = entry.outcomeNote; entries[j].outcomeSeen = false; persist() } }
    }

    func markOutcomeSeen(_ entry: Entry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].outcomeSeen = true
        persist()
    }

    /// No line of the log named a cause, but the game did end badly: use what is known about THIS game. First a tested setup (Madeira's list or Porthole's own), only for a game that
    /// has no engine lines of its own (they would be replaced); else what people who say it works great have set, from the Hub. One of them at a time, each once per game, each judged by
    /// the next run and taken back if it did not help.
    fileprivate func trySources(gameID: UUID, endedBadly: Bool) {
        guard endedBadly, let game = AppModel.shared.games.first(where: { $0.id == gameID }), game.installer != true, !hasPendingProposal(gameID) else { return }
        var tried = triedNow(gameID)
        // What the Hub switched off counts as already tried.
        for rule in [AutoFix.testedSetupRule, AutoFix.communityRule] where AutoFix.isDisabled(rule.id) { tried.insert(rule.id) }
        let ownLines = (game.engine?.config ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !tried.contains(AutoFix.testedSetupRule.id), game.testedSetupUndo == nil, ownLines.isEmpty, let rec = GameTestedSetup.recommendation(for: game) {
            if Self.asksFirst { propose(AutoFix.testedSetupRule, game: game, text: "Use the tested setup \u{201C}\(rec.title)\u{201D} for this game.") } else { applyTestedSetup(to: gameID) }
            return
        }
        guard !tried.contains(AutoFix.communityRule.id), game.settingsUndo == nil else { return }
        Task { @MainActor in
            guard let plan = try? await CommunitySettings.load(for: game), !plan.changes.isEmpty,
                  let now = AppModel.shared.games.first(where: { $0.id == gameID }), !self.triedNow(gameID).contains(AutoFix.communityRule.id), !self.hasPendingProposal(gameID) else {
                LogStore.shared.log("[autofix] \(game.name): nothing shared by others to use")
                return
            }
            let list = plan.changes.map { "\($0.title): \($0.from) \u{2192} \($0.to)" }.joined(separator: "; ")
            if Self.asksFirst { self.propose(AutoFix.communityRule, game: now, text: "Change these settings for this game, as people who say it works great have them: \(list).") }
            else { self.applyCommunity(plan, to: gameID) }
        }
    }

    /// A tested setup (Madeira's list or Porthole's own) applied to a game that has no engine lines of its own.
    private func applyTestedSetup(to gameID: UUID) {
        guard let game = AppModel.shared.games.first(where: { $0.id == gameID }), game.testedSetupUndo == nil,
              (game.engine?.config ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let rec = GameTestedSetup.recommendation(for: game) else {
            LogStore.shared.log("[autofix] \(gameID): the tested setup no longer applies")
            return
        }
        var snapshot: GameTestedSetup.Undo?
        AppModel.shared.update(game) { g in snapshot = GameTestedSetup.apply(rec, to: &g); g.testedSetupUndo = snapshot }
        record(AutoFix.testedSetupRule, game: game, undo: [Undo(key: "tested-setup", before: Self.json(snapshot))], done: "The tested setup \u{201C}\(rec.title)\u{201D} was applied to this game.")
    }

    /// What people who say the game works great have set, applied to this game.
    private func applyCommunity(_ plan: CommunitySettings.Plan, to gameID: UUID) {
        guard let now = AppModel.shared.games.first(where: { $0.id == gameID }), now.settingsUndo == nil else { return }
        AppModel.shared.update(now) { RecommendedSettings.apply(plan.changes, recommended: plan.recommended, to: &$0) }
        let snapshot = AppModel.shared.games.first(where: { $0.id == gameID })?.settingsUndo
        let list = plan.changes.map { "\($0.title): \($0.from) \u{2192} \($0.to)" }.joined(separator: "; ")
        record(AutoFix.communityRule, game: now, undo: [Undo(key: "community-settings", before: Self.json(snapshot))], done: "Changed for this game: \(list).")
    }

    // MARK: Asking first

    private func hasPendingProposal(_ gameID: UUID) -> Bool { entries.contains { $0.gameID == gameID && $0.state == "proposed" } }

    /// A fix was found. Asks first (nothing changes) unless the person turned that off; a rule that changes nothing only explains, so there is nothing to ask.
    private func offerOrApply(_ rule: AutoFix.Rule, to gameID: UUID) {
        guard rule.change != .advice, Self.asksFirst else { apply(rule, to: gameID); return }
        guard let game = AppModel.shared.games.first(where: { $0.id == gameID }), !hasPendingProposal(gameID) else { return }
        propose(rule, game: game, text: AutoFix.proposal(for: rule.change))
    }

    private func propose(_ rule: AutoFix.Rule, game: Game, text: String) {
        var entry = Entry(gameID: game.id, gameName: game.name, ruleID: rule.id, title: rule.title, reason: rule.reason, done: text, at: Date(),
                          build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?", undo: [])
        entry.state = "proposed"
        entries.append(entry)
        persist()
        LogStore.shared.log("[autofix] \(game.name): \(rule.id): proposed, waiting for the person (\(text)) (\(rule.reason))")
    }

    /// The person said yes (to a new proposal, or to one they had said no to): the change is made now, and shown with Undo like any other.
    func accept(_ entry: Entry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }), entries[i].state != nil else { return }
        let ruleID = entries[i].ruleID, gameID = entries[i].gameID
        entries.remove(at: i)
        persist()
        guard AppModel.shared.games.contains(where: { $0.id == gameID }) else { return }
        if AutoFix.isDisabled(ruleID) { LogStore.shared.log("[autofix] \(entry.gameName): \(ruleID) was switched off by the Hub since it was proposed; nothing changed"); return }
        LogStore.shared.log("[autofix] \(entry.gameName): \(ruleID): accepted by the person")
        switch ruleID {
        case AutoFix.testedSetupRule.id: applyTestedSetup(to: gameID)
        case AutoFix.communityRule.id:
            guard let game = AppModel.shared.games.first(where: { $0.id == gameID }) else { return }
            Task { @MainActor in
                guard let plan = try? await CommunitySettings.load(for: game), !plan.changes.isEmpty else { LogStore.shared.log("[autofix] \(game.name): nothing shared by others to use any more"); return }
                self.applyCommunity(plan, to: gameID)
            }
        default:
            if let rule = AutoFix.rule(id: ruleID) { apply(rule, to: gameID) }
            else { LogStore.shared.log("[autofix] \(entry.gameName): \(ruleID) is not in the rule list any more (the Hub changed it since it was suggested); nothing changed") }
        }
    }

    /// The person said no: the game stays as it is and this fix is not offered again (Settings can still apply it).
    func decline(_ entry: Entry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }), entries[i].state == "proposed" else { return }
        entries[i].state = "declined"
        entries[i].seen = true
        persist()
        LogStore.shared.log("[autofix] \(entry.gameName): \(entry.ruleID): declined by the person; nothing changed")
    }

    /// A game's stored program was not there and was found again inside the game's folder (ProgramRepair): the game now points at it. Nothing to undo, so the notice only says it.
    func recordProgramRepair(_ game: Game, from old: String, to new: String) {
        let rule = AutoFix.programMovedRule
        let entry = Entry(gameID: game.id, gameName: game.name, ruleID: rule.id, title: rule.title, reason: rule.reason, done: "It now points at \(new) (it was \(old)).", at: Date(),
                          build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?", undo: [], adviceOnly: true)
        entries.append(entry)
        persist()
        LogStore.shared.log("[autofix] \(game.name): program-moved: \(old) -> \(new)")
    }

    private static func json<T: Encodable>(_ value: T?) -> String? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func record(_ rule: AutoFix.Rule, game: Game, undo: [Undo], done: String) {
        let entry = Entry(gameID: game.id, gameName: game.name, ruleID: rule.id, title: rule.title, reason: rule.reason, done: done, at: Date(),
                          build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?", undo: undo)
        entries.append(entry)
        persist()
        LogStore.shared.log("[autofix] \(game.name): \(rule.id): \(done)")
    }

    private func triedNow(_ id: UUID) -> Set<String> { Set(entries.filter { $0.gameID == id }.map(\.ruleID)) }

    private func apply(_ rule: AutoFix.Rule, to gameID: UUID) {
        guard let game = AppModel.shared.games.first(where: { $0.id == gameID }) else { return }
        var undo: [Undo] = []
        AppModel.shared.update(game) { g in
            switch rule.change {
            case .avx:
                undo.append(Undo(key: "engine.avx", before: g.engine?.avx.map { $0 ? "1" : "0" }))
                var e = g.engine ?? GameEngine(); e.avx = true; g.engine = e
            case .swap(let mb, let coverage):
                undo.append(Undo(key: "settings.swapMB", before: g.settings?.swapMB.map(String.init)))
                undo.append(Undo(key: "settings.swapCoverage", before: g.settings?.swapCoverage))
                var s = g.settings ?? GameSettings(); s.swapMB = mb; s.swapCoverage = coverage; g.settings = s
            case .swapCoverage(let coverage):
                undo.append(Undo(key: "settings.swapCoverage", before: g.settings?.swapCoverage))
                var s = g.settings ?? GameSettings(); s.swapCoverage = coverage; g.settings = s
            case .config(_, let line):
                undo.append(Undo(key: "engine.config", before: g.engine?.config))
                var e = g.engine ?? GameEngine()
                e.config = (e.config.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 + "\n" } ?? "") + line
                g.engine = e
            case .advice:
                break
            }
        }
        let entry = Entry(gameID: gameID, gameName: game.name, ruleID: rule.id, title: rule.title, reason: rule.reason, done: rule.done, at: Date(),
                          build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?", undo: undo, adviceOnly: rule.change == .advice ? true : nil)
        entries.append(entry)
        persist()
        LogStore.shared.log("[autofix] \(game.name): \(rule.id): \(rule.done) (\(rule.reason))")
    }

    /// Puts the old values back.
    func undo(_ entry: Entry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }), !entries[i].undone,
              let game = AppModel.shared.games.first(where: { $0.id == entry.gameID }) else { return }
        AppModel.shared.update(game) { g in
            for u in entry.undo {
                switch u.key {
                case "engine.avx":
                    var e = g.engine ?? GameEngine(); e.avx = u.before.map { $0 == "1" }; g.engine = e.isEmpty ? nil : e
                case "settings.swapMB":
                    var s = g.settings ?? GameSettings(); s.swapMB = u.before.flatMap(Int.init); g.settings = s.isEmpty ? nil : s
                case "tested-setup":
                    if let text = u.before, let data = text.data(using: .utf8), let snapshot = try? JSONDecoder().decode(GameTestedSetup.Undo.self, from: data) {
                        g.engine = snapshot.engine; g.settings = snapshot.settings
                    }
                    g.testedSetupUndo = nil
                case "community-settings":
                    if let text = u.before, let data = text.data(using: .utf8), let snapshot = try? JSONDecoder().decode(RecommendedSettings.Undo.self, from: data) {
                        g.settings = snapshot.settings; g.launchDirect = snapshot.launchDirect
                    }
                    g.settingsUndo = nil
                case "engine.config":
                    var e = g.engine ?? GameEngine(); e.config = u.before; g.engine = e.isEmpty ? nil : e
                case "settings.swapCoverage":
                    var s = g.settings ?? GameSettings(); s.swapCoverage = u.before; g.settings = s.isEmpty ? nil : s
                default: break
                }
            }
        }
        entries[i].undone = true
        entries[i].seen = true
        persist()
        LogStore.shared.log("[autofix] \(entry.gameName): \(entry.ruleID) undone")
    }

    func markSeen(_ entry: Entry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].seen = true
        persist()
    }

    private static func freeStorageMB() -> Int {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let bytes = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        return Int(bytes >> 20)
    }
}
