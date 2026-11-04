// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import CryptoKit
import SwiftUI

/// What one play session measured (Telemetry samples once a second while a game runs).
struct CompatSessionStats: Codable, Equatable {
    var fpsAvg: Double?       // mean of the seconds in which the game drew anything
    var fpsLow: Double?       // the slowest 5% of those seconds
    var minutes: Int
    var thermal: String       // the hottest the phone got: cool, warm, hot, critical
    var samples: Int

    var summary: String {
        var parts: [String] = []
        if let fpsAvg { parts.append(String(format: "%.0f fps average", fpsAvg)) }
        if let fpsLow { parts.append(String(format: "%.0f fps low", fpsLow)) }
        parts.append("\(minutes) min")
        parts.append("phone got \(thermal == "critical" ? "very hot" : thermal)")
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// Everything about compatibility reporting that lives on this phone: badges for the Library, which game is which, the play session that just ended,
/// and reports waiting for the server to be reachable.
@MainActor
final class CompatStore: ObservableObject {
    static let shared = CompatStore()

    /// A question shown on the Library after a game: "How did it run?". Also made when the app closed while a game was running.
    struct Prompt: Codable, Equatable {
        var gameID: UUID
        var gameName: String
        var stats: CompatSessionStats?
        var crashed: Bool
        var at: Date
    }
    struct Queued: Codable, Identifiable, Equatable {
        var id = UUID()
        var gameID: UUID?
        var payload: CompatReportPayload
        /// The report's packed log, kept in its own file (Application Support/CompatQueue) while the report waits: a log is megabytes, the queue is a small list.
        var logFile: String?
    }

    private static var queueFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CompatQueue", isDirectory: true)
    }
    private struct Marker: Codable { var gameID: UUID; var gameName: String; var started: Date; var stats: CompatSessionStats? }
    private struct Saved: Codable {
        var fingerprints: [String: String] = [:]           // game id -> SHA-256 of its main program, once worked out
        var fingerprintStamps: [String: String]?           // game id -> size and modified time of the file that was hashed (older saves have none)
        var queue: [Queued] = []
        var prompt: Prompt?
        var marker: Marker?
        var reported: [String: Date] = [:]                 // "game id|engine" -> when (a new engine asks again; an app update alone does not)
        var lastStats: [String: CompatSessionStats] = [:]  // game id -> its most recent session
        var badgeCache: [String: CompatBadge] = [:]        // compat id -> last answer (for when the server is unreachable)
        var badgeCacheEngine: String?                      // the engine those answers were for
    }

    @Published private(set) var badges: [UUID: CompatBadge] = [:]
    /// Games the server was asked about and has no verdict for on this engine. Only filled from a real answer, so being offline never labels a game "not yet tested".
    @Published private(set) var untested: Set<UUID> = []
    /// Badges for Steam games by app id (the Steam tab shows these for games that are not installed too).
    @Published private(set) var steamBadges: [Int: CompatBadge] = [:]
    /// Steam app ids the server answered for and has no verdict for on this engine.
    @Published private(set) var steamUntested: Set<Int> = []
    @Published private(set) var prompt: Prompt?
    @Published private(set) var queuedCount = 0
    @Published var lastError: String?

    private var saved = Saved()
    private var refreshing = false
    /// Set when this launch found that the last run ended while a game was running (a crash, iOS closing the app, or a force-quit): which game, and when it started.
    private(set) var endedUnexpectedly: (gameName: String, started: Date)?
    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("f4-compat.json")
    }

    static let showBadgesKey = "f4.compat.badges"
    static let askKey = "f4.compat.ask"
    var showBadges: Bool { UserDefaults.standard.object(forKey: Self.showBadgesKey) as? Bool ?? true }
    var askAfterPlaying: Bool { UserDefaults.standard.object(forKey: Self.askKey) as? Bool ?? true }

    private init() {
        if let data = try? Data(contentsOf: fileURL), let loaded = try? JSONDecoder().decode(Saved.self, from: data) { saved = loaded }
        // A session marker that is still here means the app ended while a game was running (a crash, iOS closing it, or a force-quit).
        if let marker = saved.marker {
            saved.marker = nil
            endedUnexpectedly = (marker.gameName, marker.started)
            if askAfterPlaying, Date().timeIntervalSince(marker.started) > 60 {
                saved.prompt = Prompt(gameID: marker.gameID, gameName: marker.gameName, stats: marker.stats, crashed: true, at: Date())
                if let stats = marker.stats { saved.lastStats[marker.gameID.uuidString] = stats }
            }
            persist()
        }
        prompt = saved.prompt
        queuedCount = saved.queue.count
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Who is who

    func steamID(for game: Game) -> Int? {
        if let id = game.dockAppID, id > 0 { return id }
        if let id = game.steamAppID, id > 0 { return id }
        return nil
    }

    func fingerprint(for game: Game) -> String? { saved.fingerprints[game.id.uuidString] }

    /// The game's compat ids on the server, most specific first. A Steam match is only a guess for a game that was not downloaded through Steam, so both are tried.
    func candidateIDs(for game: Game) -> [String] {
        var ids: [String] = []
        if let steam = steamID(for: game) { ids.append("steam:\(steam)") }
        if let fp = fingerprint(for: game) { ids.append("file:\(fp.prefix(32))") }
        return ids
    }

    func lastStats(for game: Game) -> CompatSessionStats? { saved.lastStats[game.id.uuidString] }

    /// SHA-256 of the game's main program: the same file gives the same id on every phone, and a different build gives a different one.
    /// The answer is kept with the file's size and modified time; when the program is replaced (a game update, a patched copy) the next call hashes it again,
    /// so a changed program is identified as what it is now and the id does not stay on the old build.
    @discardableResult
    func ensureFingerprint(for game: Game) async -> String? {
        guard game.installer != true, let url = AppModel.unixURL(forWindows: game.exe) else { return fingerprint(for: game) }
        let key = game.id.uuidString
        let known = fingerprint(for: game), knownStamp = saved.fingerprintStamps?[key]
        let result: (digest: String, stamp: String)? = await Task.detached(priority: .utility) {
            let stamp = Self.stamp(of: url)
            // A file that can't be read right now (the drive is away) keeps what is known; a save from before stamps existed is trusted once and stamped.
            guard let stamp else { return nil }
            if let known, knownStamp == nil || knownStamp == stamp { return (known, stamp) }
            guard let digest = Self.sha256(of: url) else { return nil }
            return (digest, stamp)
        }.value
        guard let result else { return known }
        if result.digest != known || knownStamp != result.stamp {
            saved.fingerprints[key] = result.digest
            var stamps = saved.fingerprintStamps ?? [:]; stamps[key] = result.stamp; saved.fingerprintStamps = stamps
            persist()
        }
        return result.digest
    }

    nonisolated static func stamp(of url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), let size = a[.size] as? NSNumber else { return nil }
        let time = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size.int64Value)-\(Int(time))"
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Badges

    /// The public list of badges (every game with reports), loaded as a whole so the server never learns which games are in the library. Kept in memory for
    /// ten minutes; nil when the server can't be reached.
    private var snapshot: (at: Date, engine: String, badges: [String: CompatBadge])?

    private func loadSnapshot() async -> [String: CompatBadge]? {
        if let s = snapshot, s.engine == CompatEngine.id, Date().timeIntervalSince(s.at) < 600 { return s.badges }
        do {
            let all = try await CompatClient.standard().allBadges(device: CompatDeviceInfo.current?.id)
            snapshot = (Date(), CompatEngine.id, all)
            LogStore.shared.log("[compat] badge list for engine \(CompatEngine.id): \(all.count) game(s); matched on this device")
            return all
        } catch {
            // With no network at all this is expected, not an error.
            LogStore.shared.log("[compat] couldn't load the badge list: \(error.localizedDescription)", level: NetworkStatus.shared.isOnline ? .error : .info)
            return nil
        }
    }

    /// Badges for every library game. The whole public list is downloaded and the library is matched against it here. Falls back to the last answers
    /// when the server can't be reached.
    func refreshBadges(for games: [Game]) async {
        guard showBadges, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        for game in games { await ensureFingerprint(for: game) }   // cheap unless a program changed since it was last hashed
        let idsByGame = Dictionary(uniqueKeysWithValues: games.map { ($0.id, candidateIDs(for: $0)) })
        let all = Array(Set(idsByGame.values.flatMap { $0 }))
        guard !all.isEmpty else { return }
        var answer: [String: CompatBadge]
        var answered = false
        // Answers kept from another engine would show badges that no longer apply.
        if saved.badgeCacheEngine != CompatEngine.id { saved.badgeCache = [:]; saved.badgeCacheEngine = CompatEngine.id }
        if let list = await loadSnapshot() {
            answer = list
            for id in all { saved.badgeCache[id] = answer[id] }          // a game that lost all its reports drops out of the cache too
            persist()
            answered = true
            LogStore.shared.log("[compat] badges for engine \(CompatEngine.id): \(all.count) game id(s) of the library, \(all.filter { answer[$0] != nil }.count) have reports")
        } else {
            answer = saved.badgeCache.compactMapValues { $0 }
        }
        var result: [UUID: CompatBadge] = [:]
        for (gameID, ids) in idsByGame {
            let found = ids.compactMap { answer[$0] }
            // A badge if there is one; otherwise "reports exist, but not on this engine yet".
            if let hit = found.first(where: { $0.verdict != nil }) ?? found.first(where: { $0.needsReview }) { result[gameID] = hit }
        }
        badges = result
        if answered { untested = Set(idsByGame.compactMap { gameID, ids in !ids.isEmpty && result[gameID]?.verdict == nil ? gameID : nil }) }
    }

    /// Asks the server for the badges of these Steam games (installed or not). In memory only; a failed request leaves the last answers alone.
    func refreshSteamBadges(ids: [Int]) async {
        guard showBadges, !ids.isEmpty else { return }
        guard let answer = await loadSnapshot() else { return }       // the public list, matched here: the server is not told which games these are
        var found: [Int: CompatBadge] = [:], none: Set<Int> = []
        for id in ids {
            if let b = answer["steam:\(id)"], b.verdict != nil || b.needsReview { found[id] = b }
            if answer["steam:\(id)"]?.verdict == nil { none.insert(id) }
        }
        // Merge: asking about one game (its page) must not wipe the badges of the others.
        for id in ids { steamBadges[id] = found[id] }
        steamUntested.subtract(ids); steamUntested.formUnion(none)
    }

    /// True once the server has answered and there is no verdict for this game on this engine (never reported, or the engine changed since).
    func isUntested(_ game: Game) -> Bool { untested.contains(game.id) && badges[game.id]?.verdict == nil }

    // MARK: Reports

    /// `logSent`: the game's log went with the report. Every report waits for the developer's approval before it is public, so there is nothing else to say about when it appears.
    enum SubmitResult { case sent(logSent: Bool), queued }

    /// What a report about `game` would be filed under. A Steam game (downloaded here, or copied from Steam and matched) is shared by everyone who has it;
    /// anything else is identified by its program's fingerprint.
    func gameRef(for game: Game, source: CompatSource) async -> CompatReportPayload.GameRef? {
        if let steam = steamID(for: game), source == .steam || game.dockAppID != nil {
            let name = SteamStore.shared.owned.first(where: { $0.id == steam })?.name ?? game.name
            return .init(kind: "steam", steamAppID: steam, fingerprint: nil, title: name)
        }
        guard let fp = await ensureFingerprint(for: game) else { return nil }
        return .init(kind: "file", steamAppID: nil, fingerprint: fp, title: game.name)
    }

    /// What this game launches with right now: its own overrides over the global settings, and how it is started.
    func currentSettings(for game: Game) -> CompatSettings {
        let s = LaunchSettings.resolve(for: game)
        let power = s.power == .performance ? "performance" : s.power == .saver ? "saver" : "balanced"
        return CompatSettings(
            launch: game.dockAppID != nil && game.launchDirect != true ? "steam" : "direct", power: power, keepModeWhenHot: s.keepModeWhenHot,
            swapMB: max(0, s.swapMB), swapCoverage: ["", "blocks", "wide"].contains(s.swapCoverage) ? s.swapCoverage : "", vramMB: max(0, s.vramMB),
            audioCushionMs: min(2000, max(0, s.audioCushionMs)), preciseMath: s.preciseMath, desktopDisplay: s.dockDesktop,
            controls: (game.controls ?? .standard) == .firstPerson ? "firstPerson" : "standard")
    }

    func submit(game: Game, rating: CompatVerdict, stability: CompatStability, tags: [CompatTag], source: CompatSource,
                stats: CompatSessionStats?, shareNumbers: Bool, shareSettings: Bool, comment: String, log: CompatLog.Gathered? = nil) async throws -> SubmitResult {
        guard let device = CompatDeviceInfo.current else { throw CompatError.notAvailable("Reports can only be sent from an iPhone or iPad.") }
        let effectiveSource: CompatSource = game.dockAppID != nil ? .steam : source
        guard let ref = await gameRef(for: game, source: effectiveSource) else { throw CompatError.notAvailable("Couldn't read this game's program to identify it.") }
        var perf: CompatPerf?
        if let stats {
            // Without the person's OK to share the measurements, only how long they played goes along (the server needs that much).
            perf = shareNumbers ? CompatPerf(fpsAvg: stats.fpsAvg, fpsLow: stats.fpsLow, minutes: stats.minutes, thermal: stats.thermal)
                                : CompatPerf(fpsAvg: nil, fpsLow: nil, minutes: stats.minutes, thermal: nil)
        } else if let seconds = game.playSeconds {
            perf = CompatPerf(fpsAvg: nil, fpsLow: nil, minutes: Int(seconds / 60), thermal: nil)
        }
        let payload = CompatReportPayload(
            game: ref, device: .init(id: device.id, name: device.name), ios: CompatDeviceInfo.iOSVersion, appVersion: CompatDeviceInfo.appVersion, engine: CompatEngine.id,
            rating: rating, stability: stability, tags: tags, source: effectiveSource, perf: perf,
            settings: shareSettings ? currentSettings(for: game) : nil, comment: comment.trimmingCharacters(in: .whitespacesAndNewlines))
        var withLog = payload
        withLog.logGz = log?.base64
        do {
            var logSent = log != nil
            let saved: CompatClient.Saved
            do { saved = try await CompatClient.standard().submit(withLog) }
            catch let error as CompatError where log != nil && Self.refusesLog(error) {
                // The server would not take the log (too large, or no room left for logs): the report matters more, so it goes without.
                logSent = false
                LogStore.shared.log("[compat] the server refused the log (\(error.localizedDescription)); sending the report without it", level: .error)
                saved = try await CompatClient.standard().submit(payload)
            }
            markReported(game)
            clearPrompt(for: game)
            await refreshBadges(for: AppModel.shared.games)
            return .sent(logSent: logSent && (saved.logStored ?? false))
        } catch let error as CompatError where error.isTemporary {
            var item = Queued(gameID: game.id, payload: payload)
            if let log { item.logFile = Self.keepForQueue(log.packed, id: item.id) }
            saved.queue.append(item)
            queuedCount = saved.queue.count
            markReported(game)
            clearPrompt(for: game)
            persist()
            return .queued
        }
    }

    /// 413 (log too large) and 507 (the server's room for logs is full): the report can still be sent without its log.
    private static func refusesLog(_ error: CompatError) -> Bool {
        if case .server(let code, _) = error { return code == 413 || code == 507 }
        return false
    }

    private static func keepForQueue(_ packed: Data, id: UUID) -> String? {
        let name = "\(id.uuidString).gz"
        try? FileManager.default.createDirectory(at: queueFolder, withIntermediateDirectories: true)
        guard (try? packed.write(to: queueFolder.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }

    /// Sends reports that were waiting for the server. Called when the app opens and comes back to the front.
    func flushQueue() async {
        guard !saved.queue.isEmpty else { return }
        let before = saved.queue.count
        var remaining: [Queued] = []
        for item in saved.queue {
            var payload = item.payload
            let file = item.logFile.map { Self.queueFolder.appendingPathComponent($0) }
            if let file, let packed = try? Data(contentsOf: file) { payload.logGz = packed.base64EncodedString() }
            do {
                do { _ = try await CompatClient.standard().submit(payload) }
                catch let error as CompatError where payload.logGz != nil && Self.refusesLog(error) { payload.logGz = nil; _ = try await CompatClient.standard().submit(payload) }
                if let file { try? FileManager.default.removeItem(at: file) }
            }
            catch let error as CompatError where error.isTemporary { remaining.append(item) }
            catch { if let file { try? FileManager.default.removeItem(at: file) } /* the server refused it for good: sending it again would not help */ }
        }
        saved.queue = remaining
        queuedCount = remaining.count
        persist()
        if remaining.count < before { await refreshBadges(for: AppModel.shared.games) }
    }

    private func markReported(_ game: Game) {
        saved.reported["\(game.id.uuidString)|\(CompatEngine.id)"] = Date()
        persist()
    }

    func hasReported(_ game: Game) -> Bool { saved.reported["\(game.id.uuidString)|\(CompatEngine.id)"] != nil }

    // MARK: Play sessions

    func sessionBegan(_ game: Game) {
        guard CompatDeviceInfo.current != nil, game.installer != true else { return }
        saved.marker = Marker(gameID: game.id, gameName: game.name, started: Date(), stats: nil)
        persist()
    }

    /// Called about once a minute while a game runs, so a crash still leaves the numbers behind.
    func checkpoint(_ stats: CompatSessionStats) {
        guard var marker = saved.marker else { return }
        marker.stats = stats
        saved.marker = marker
        persist()
    }

    func sessionEnded(_ game: Game, stats: CompatSessionStats?) {
        saved.marker = nil
        if let stats { saved.lastStats[game.id.uuidString] = stats }
        if askAfterPlaying, CompatDeviceInfo.current != nil, !hasReported(game), (stats?.minutes ?? 0) >= 5 {
            saved.prompt = Prompt(gameID: game.id, gameName: game.name, stats: stats, crashed: false, at: Date())
            prompt = saved.prompt
        }
        persist()
    }

    func dismissPrompt() { saved.prompt = nil; prompt = nil; persist() }

    private func clearPrompt(for game: Game) {
        if saved.prompt?.gameID == game.id { saved.prompt = nil; prompt = nil; persist() }
    }

    /// Forgets everything stored here (Settings ▸ Compatibility ▸ Reset).
    func forgetLocalData() {
        saved = Saved(); prompt = nil; queuedCount = 0; badges = [:]; untested = []
        persist()
        CompatIdentity.reset()
    }
}
