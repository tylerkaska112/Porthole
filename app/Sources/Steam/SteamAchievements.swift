// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// A game's achievements as Steam keeps them for the account: the schema (names, descriptions, pictures) and the time each was unlocked.
// Read-only: this asks Steam for the account's stats the way Steam's own client does when it opens a game's page; nothing is written back.
import Foundation

/// One achievement of a game, with this account's progress.
struct SteamAchievement: Identifiable, Equatable {
    var apiName: String
    var name: String
    var detail: String
    var hidden: Bool
    var icon: String? = nil
    var iconGray: String? = nil
    var unlocked: Date? = nil
    /// Share of all players who have it, 0...100, when Steam's public numbers were reachable.
    var percent: Double? = nil
    var id: String { apiName }

    /// Steam's schema names the picture as a file name that already ends in .jpg; a bare hash gets the extension added.
    func iconURL(app: Int) -> URL? {
        guard let file = (unlocked != nil ? icon : (iconGray ?? icon)), !file.isEmpty else { return nil }
        if file.hasPrefix("http") { return URL(string: file) }
        let name = file.contains(".") ? file : file + ".jpg"
        return URL(string: "https://shared.fastly.steamstatic.com/community_assets/images/apps/\(app)/\(name)")
    }
}

/// What Steam's stats answer holds: the schema bytes and, per stat id that carries achievements, one unlock time per bit (0 = not unlocked).
struct SteamUserStatsReply: Equatable {
    var schema: Data
    var blocks: [Int: [UInt32]]
}

enum SteamAchievementParser {
    /// Reads ClientGetUserStatsResponse. Throws Steam's reason when the answer is not a success.
    static func reply(from body: Data) -> Result<SteamUserStatsReply, SteamContentError> {
        guard let fields = PBFields(body) else { return .failure(SteamContentError(message: "Steam's answer about achievements could not be read.")) }
        let code = fields.int(2) ?? 2
        guard code == 1 else {
            return .failure(SteamContentError(message: code == 8 || code == 2 ? "Steam has no achievements for this game." : "Steam would not give the achievements (error \(code))."))
        }
        var blocks: [Int: [UInt32]] = [:]
        for block in fields.messages(6) {
            guard let id = block.uint(1) else { continue }
            var times: [UInt32] = []
            for value in block.values[2] ?? [] {
                switch value {
                case .fixed32(let t): times.append(t)
                case .varint(let t): times.append(UInt32(truncatingIfNeeded: t))
                case .bytes(let packed):                                     // a packed run of fixed32s
                    let bytes = Array(packed)
                    var at = 0
                    while at + 4 <= bytes.count {
                        times.append(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
                        at += 4
                    }
                default: break
                }
            }
            blocks[Int(id)] = times
        }
        return .success(SteamUserStatsReply(schema: fields.data(4) ?? Data(), blocks: blocks))
    }

    /// One achievement of the schema with where it sits: the stat (`stat`) that holds it and its bit in that stat.
    struct Definition: Equatable {
        var stat: Int
        var bit: Int
        var achievement: SteamAchievement
    }

    /// The schema is binary KeyValues: `<appid>` { stats { `<stat id>` { bits { `<bit>` { name, display { name, desc, hidden, icon, icon_gray } } } } } }.
    /// A stat with `bits` holds up to 32 achievements; the unlock block with the same id says when each bit was set.
    /// The same layout is what Steam's client keeps in `appcache/stats/UserGameStatsSchema_<appid>.bin`.
    static func definitions(schema: Data) -> [Definition] {
        guard let root = SteamBinaryKV.parse(schema) else { return [] }
        // The first level is the app id; some dumps have the stats directly at the top.
        let top: [String: Any] = (root.values.first { ($0 as? [String: Any])?["stats"] != nil } as? [String: Any]) ?? root
        guard let stats = top["stats"] as? [String: Any] else { return [] }
        var found: [Definition] = []
        for (statKey, raw) in stats {
            guard let stat = Int(statKey), let entry = raw as? [String: Any], let bits = entry["bits"] as? [String: Any] else { continue }
            for (bitKey, rawBit) in bits {
                guard let bit = Int(bitKey), let node = rawBit as? [String: Any], let api = node["name"] as? String, !api.isEmpty else { continue }
                let display = node["display"] as? [String: Any] ?? [:]
                let name = localized(display["name"]), detail = localized(display["desc"])
                found.append(Definition(stat: stat, bit: bit, achievement: SteamAchievement(
                    apiName: api, name: name.isEmpty || name.hasPrefix("#") ? api : name, detail: detail.hasPrefix("#") ? "" : detail,
                    hidden: flag(display["hidden"]), icon: nonEmpty(display["icon"]), iconGray: nonEmpty(display["icon_gray"]))))
            }
        }
        return found.sorted { ($0.stat, $0.bit) < ($1.stat, $1.bit) }
    }

    static func achievements(schema: Data, blocks: [Int: [UInt32]]) -> [SteamAchievement] {
        definitions(schema: schema).map { definition in
            var item = definition.achievement
            let when = blocks[definition.stat].flatMap { $0.indices.contains(definition.bit) ? $0[definition.bit] : nil } ?? 0
            item.unlocked = when > 0 ? Date(timeIntervalSince1970: TimeInterval(when)) : nil
            return item
        }
    }

    /// Public numbers: `{"achievementpercentages":{"achievements":[{"name":"ACH","percent":"12.3"}]}}` (the percent is a string in some answers).
    static func percentages(_ data: Data) -> [String: Double] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = ((json["achievementpercentages"] as? [String: Any])?["achievements"]) as? [[String: Any]] else { return [:] }
        var result: [String: Double] = [:]
        for item in list {
            guard let name = item["name"] as? String else { continue }
            if let number = item["percent"] as? Double { result[name] = number }
            else if let text = item["percent"] as? String, let number = Double(text) { result[name] = number }
            else if let number = item["percent"] as? Int { result[name] = Double(number) }
        }
        return result
    }

    private static func localized(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let table = value as? [String: Any] else { return "" }
        if let english = table["english"] as? String { return english }
        return table.keys.sorted().compactMap { table[$0] as? String }.first { !$0.hasPrefix("#") } ?? ""
    }
    private static func flag(_ value: Any?) -> Bool { (value as? Int).map { $0 != 0 } ?? (value as? String).map { $0 != "0" && !$0.isEmpty } ?? false }
    private static func nonEmpty(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
}

/// Newest unlocks first, then what is still locked with the commonest first.
func steamSortAchievements(_ list: [SteamAchievement]) -> (unlocked: [SteamAchievement], locked: [SteamAchievement]) {
    let unlocked = list.filter { $0.unlocked != nil }.sorted { ($0.unlocked ?? .distantPast) > ($1.unlocked ?? .distantPast) }
    let locked = list.filter { $0.unlocked == nil }.sorted { ($0.percent ?? -1) > ($1.percent ?? -1) }
    return (unlocked, locked)
}

// MARK: - Unlocks while a game runs

/// Where one achievement sits in Steam's stats: the stat id and the bit in it.
struct SteamAchievementKey: Hashable { var stat: Int; var bit: Int }

/// Steam's own record of the account's stats for a game, `appcache/stats/UserGameStats_<account>_<app>.bin` (binary KeyValues, written by Steam's client in the
/// game): `cache` { `<stat id>` { `data`, `AchievementTimes` { `<bit>` = unix time } } }. Only the achievement times are read.
enum SteamUserStatsFile {
    static func unlockTimes(_ data: Data) -> [SteamAchievementKey: UInt32] {
        guard let root = SteamBinaryKV.parse(data), let cache = root["cache"] as? [String: Any] else { return [:] }
        var found: [SteamAchievementKey: UInt32] = [:]
        for (statKey, value) in cache {
            guard let stat = Int(statKey), let entry = value as? [String: Any], let times = entry["AchievementTimes"] as? [String: Any] else { continue }
            for (bitKey, time) in times {
                guard let bit = Int(bitKey), let seconds = SteamJSON.int(time), seconds > 0 else { continue }
                found[SteamAchievementKey(stat: stat, bit: bit)] = UInt32(truncatingIfNeeded: seconds)
            }
        }
        return found
    }

    /// Achievements in `current` that `known` did not have and that were unlocked at or after `since` (older ones appearing are Steam syncing the account's history
    /// into the file when the game starts, not something the person just did), oldest first.
    static func newUnlocks(known: Set<SteamAchievementKey>, current: [SteamAchievementKey: UInt32], since: Date) -> [(key: SteamAchievementKey, time: UInt32)] {
        current.filter { !known.contains($0.key) && TimeInterval($0.value) >= since.timeIntervalSince1970 }
            .map { (key: $0.key, time: $0.value) }
            .sorted { ($0.time, $0.key.stat, $0.key.bit) < ($1.time, $1.key.stat, $1.key.bit) }
    }
}

/// While a Steam game runs in Steam's client, watches the client's stats file for the game and reports each achievement that gets unlocked.
/// Read-only; it needs no connection to Steam (which is closed while a game runs).
@MainActor
final class SteamAchievementWatcher {
    static let shared = SteamAchievementWatcher()
    private var task: Task<Void, Never>?

    func stop() { task?.cancel(); task = nil }

    func start(steamFolder: URL, account: String, appID: Int, isRunning: @escaping @MainActor () -> Bool, onUnlock: @escaping @MainActor (SteamAchievement) -> Void) {
        stop()
        let stats = steamFolder.appendingPathComponent("appcache/stats", isDirectory: true)
        let statsFile = stats.appendingPathComponent("UserGameStats_\(account)_\(appID).bin")
        let schemaFile = stats.appendingPathComponent("UserGameStatsSchema_\(appID).bin")
        let startedAt = Date()
        task = Task { @MainActor in
            var known: Set<SteamAchievementKey> = []
            var seenStamp: (size: Int, mtime: Date)?
            var definitions: [SteamAchievementKey: SteamAchievement] = [:]
            var schemaStamp: (size: Int, mtime: Date)?
            var baselineTaken = false
            func stamp(_ url: URL) -> (size: Int, mtime: Date)? {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
            SteamLog.event("[achievements] watching \(statsFile.lastPathComponent)")
            while !Task.isCancelled, isRunning() {
                if let now = stamp(statsFile), seenStamp.map({ $0.size != now.size || $0.mtime != now.mtime }) ?? true, let data = try? Data(contentsOf: statsFile) {
                    seenStamp = now
                    let current = SteamUserStatsFile.unlockTimes(data)
                    if !baselineTaken {
                        known = Set(current.keys); baselineTaken = true
                        SteamLog.event("[achievements] app \(appID): \(known.count) unlocked at the start")
                    } else {
                        let fresh = SteamUserStatsFile.newUnlocks(known: known, current: current, since: startedAt.addingTimeInterval(-60))
                        known.formUnion(current.keys)
                        if !fresh.isEmpty {
                            if let now = stamp(schemaFile), schemaStamp.map({ $0.size != now.size || $0.mtime != now.mtime }) ?? true, let schema = try? Data(contentsOf: schemaFile) {
                                schemaStamp = now
                                definitions = Dictionary(SteamAchievementParser.definitions(schema: schema).map { (SteamAchievementKey(stat: $0.stat, bit: $0.bit), $0.achievement) },
                                                         uniquingKeysWith: { a, _ in a })
                            }
                            for item in fresh {
                                var achievement = definitions[item.key] ?? SteamAchievement(apiName: "stat\(item.key.stat)bit\(item.key.bit)", name: "Achievement unlocked", detail: "", hidden: false)
                                achievement.unlocked = Date(timeIntervalSince1970: TimeInterval(item.time))
                                SteamLog.event("[achievements] app \(appID): unlocked \(achievement.apiName) (\(achievement.name))")
                                onUnlock(achievement)
                            }
                        }
                    }
                } else if !baselineTaken, stamp(statsFile) == nil {
                    // No stats file yet (nothing ever stored for this game): every unlock from now on is new.
                    baselineTaken = true
                    SteamLog.event("[achievements] app \(appID): no stats file yet")
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
}

/// The game's whole achievement list from the files Steam's client keeps on the device (the schema and the stats file): works while the game runs and with no connection.
enum SteamLocalAchievements {
    static func load(steamFolder: URL, account: String, appID: Int) -> [SteamAchievement] {
        let stats = steamFolder.appendingPathComponent("appcache/stats", isDirectory: true)
        guard let schema = try? Data(contentsOf: stats.appendingPathComponent("UserGameStatsSchema_\(appID).bin")) else { return [] }
        let times = (try? Data(contentsOf: stats.appendingPathComponent("UserGameStats_\(account)_\(appID).bin"))).map(SteamUserStatsFile.unlockTimes) ?? [:]
        return SteamAchievementParser.definitions(schema: schema).map { definition in
            var item = definition.achievement
            if let when = times[SteamAchievementKey(stat: definition.stat, bit: definition.bit)], when > 0 { item.unlocked = Date(timeIntervalSince1970: TimeInterval(when)) }
            return item
        }
    }
}
