// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// What people who say a game works great have set, set against how this game is set now (the Hub's summary of compatibility reports; RecommendedSettings does the comparing).
/// A game's page shows it ("What works for others") and the automatic fixes use it after a game went wrong.
@MainActor
enum CommunitySettings {
    struct Plan: Equatable { var recommended: RecommendedSettings.Values; var changes: [RecommendedSettings.Change]; var reports: Int; var earlierEngine: Bool }

    enum Failure: LocalizedError {
        case notConnected
        var errorDescription: String? { "This build is not connected to a community server, so there is nothing to compare with." }
    }

    /// The plan for a game, or nil when nobody who says it works great has shared their settings for it.
    static func load(for g: Game) async throws -> Plan? {
        let compat = CompatStore.shared
        let known = compat.candidateIDs(for: g)
        let ids = known.isEmpty ? await compat.ensureFingerprint(for: g).map { ["file:\($0.prefix(32))"] } ?? [] : known
        guard !ids.isEmpty else { return nil }
        let client = CompatClient.standard()
        guard client.baseURL != nil else { throw Failure.notConnected }
        for id in ids {
            let path = "/compat/games/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)
            // The engine you run first; if nobody has reported on it yet, what people used on earlier versions.
            var earlier = false
            var detail = try? await client.get(path, [("engine", CompatEngine.id)], as: CompatGameDetail.self)
            if detail?.settingsSummary == nil { detail = try? await client.get(path, [], as: CompatGameDetail.self); earlier = true }
            guard let summary = detail?.settingsSummary else { continue }
            return plan(for: g, summary: summary, earlier: earlier)
        }
        return nil
    }

    static func plan(for g: Game, summary: CompatSettingsSummary, earlier: Bool) -> Plan {
        var rec = RecommendedSettings.Values(), counts: [String: Int] = [:]
        for item in summary.items {
            counts[item.key] = item.count
            switch (item.key, item.value) {
            case ("launch", .string(let v)): rec.launch = v
            case ("power", .string(let v)): rec.power = v
            case ("swapMB", .int(let v)): rec.swapMB = v
            case ("swapCoverage", .string(let v)): rec.swapCoverage = v
            case ("vramMB", .int(let v)): rec.vramMB = v
            case ("preciseMath", .bool(let v)): rec.preciseMath = v
            case ("desktopDisplay", .bool(let v)): rec.desktopDisplay = v
            default: break
            }
        }
        let now = CompatStore.shared.currentSettings(for: g)
        let cur = RecommendedSettings.Values(launch: now.launch, power: now.power, swapMB: now.swapMB, swapCoverage: now.swapCoverage, vramMB: now.vramMB, preciseMath: now.preciseMath, desktopDisplay: now.desktopDisplay)
        let changes = RecommendedSettings.changes(recommended: rec, counts: counts, reports: summary.reports, current: cur, steamGame: g.dockAppID != nil)
        return Plan(recommended: rec, changes: changes, reports: summary.reports, earlierEngine: earlier)
    }
}
