// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Madeira's tested setups (GameRecommendations.swift, taken from willfaust/Madeira): for about a hundred games, the engine lines and switches that were found to work on
/// their builds. Porthole never applies one by itself: a game's page shows it ("Madeira's tested setup") and the person chooses, with the previous engine lines kept for Undo.
/// Only what Porthole has a place for is applied; the rest is listed, so nothing is silently dropped.
enum GameTestedSetup {
    /// A setup Porthole's own testing found, for a game Madeira has no list for. Madeira's list cannot carry Swap, which a setup like this needs, so it is kept here: `apply` sets the
    /// swap switches on the game's own settings (and Undo puts them back with the engine lines). `tested` says on what it was found, shown to the person.
    struct OwnSetup {
        let steamAppID: Int
        let title: String
        let config: String
        var swapMB: Int? = nil
        var swapCoverage: String? = nil
        let tested: String
        var recommendationID: String { "porthole-\(steamAppID)" }
    }

    static let own: [OwnSetup] = [
        OwnSetup(steamAppID: 2670630, title: "Supermarket Simulator",
                 config: "env.MADEIRA_MIP_CLAMP_AUTO = 1\nenv.FEX_VECTORTSOENABLED = 0",
                 swapMB: 4096, swapCoverage: "",
                 tested: "an iPad with an M4 chip and 8 GB: Continue loaded a save, then 13 minutes of play at 56 to 65 frames a second with the memory staying under the app\u{2019}s 6 GB limit. Relaxing the memory order of vector code (FEX_VECTORTSOENABLED) ran faster than leaving it on; relaxing all memory ordering as well did not. On an iPad with 6 GB the limit is about 4 GB and this may not be enough.")
    ]

    static func ownSetup(for rec: GameRecommendation) -> OwnSetup? { own.first { $0.recommendationID == rec.id } }

    /// The setup for a game, or nil. The "standard" list (for games Madeira has no list for) is not offered.
    static func recommendation(for game: Game) -> GameRecommendation? {
        guard game.installer != true else { return nil }
        let id = game.dockAppID ?? game.steamAppID
        if let id, let mine = own.first(where: { $0.steamAppID == id }) {
            return GameRecommendation(id: mine.recommendationID, title: mine.title, version: 1, config: mine.config)
        }
        let found = GameRecommendations.match(windowsPath: game.exe, steamAppID: id, fileExists: driveFileExists)
        guard let found, found.id != GameRecommendations.standard.id else { return nil }
        return found
    }

    /// What applying a setup does, in words, for the confirmation: what is written, and what Porthole has no place for.
    struct Plan: Equatable {
        var title: String
        var lines: Int
        var applied: [String]
        var skipped: [String]
    }

    static func plan(_ rec: GameRecommendation) -> Plan {
        var applied: [String] = [], skipped: [String] = []
        let lines = MadeiraConfig.parse(rec.fileText).count
        if rec.avx != nil { applied.append("AVX \(rec.avx == true ? "on" : "off")") }
        if let card = card(rec) { applied.append("graphics card: \(card.title)") }
        if rec.wineVCRT == true { applied.append("Wine's C++ runtime") }
        if rec.fastSync == false { applied.append("fast synchronization off") }
        if let sem = rec.semaphoreFastPath { applied.append("fast semaphore waits \(sem ? "on" : "off")") }
        if let size = resolution(rec) { applied.append("screen size \(DisplayResolution.title(id: size, screenAspect: 16.0 / 9.0).lowercased())") }
        else if rec.resolution != nil { skipped.append("screen size \(rec.resolution ?? "")") }
        if rec.launchMode == "desktop" { applied.append("Wine desktop display") }
        if let fps = rec.fpsMode, fps != 1 { skipped.append("FPS limit (\(["0": "display maximum", "2": "uncapped", "3": "30", "4": "40"]["\(fps)"] ?? "\(fps)")): set it in the game's menu") }
        if let display = rec.display, display != "fit" { skipped.append("aspect and scaling \(display)") }
        if rec.startServices == true { skipped.append("starting Windows services first") }
        if let mine = ownSetup(for: rec), let mb = mine.swapMB {
            applied.append("swap \(mb == 0 ? "off" : "\(mb / 1024) GB")" + (mine.swapCoverage == "" ? ", large blocks (8 MB and up)" : ""))
        }
        return Plan(title: rec.title, lines: lines, applied: applied, skipped: skipped)
    }

    /// The graphics card choice a setup's NVIDIA switches stand for (the older card wins, as its Direct3D 9 ids do in Madeira).
    private static func card(_ rec: GameRecommendation) -> GPUCard? {
        if rec.olderNvidia == true { return GPUCards.card("nvidia-7900gs") }
        if rec.nvidia == true { return GPUCards.card("nvidia-rtx3060") }
        return nil
    }

    private static func resolution(_ rec: GameRecommendation) -> String? {
        guard let value = rec.resolution else { return nil }
        if value == GameRecommendation.screen720 { return "screen720" }
        return DisplayResolution.offered(value)
    }

    /// Writes the setup into the game. The engine lines are replaced (the previous ones are returned so Undo can bring them back); the switches Porthole keeps in
    /// `GameEngine` and `GameSettings` are set. Returns the previous state.
    @discardableResult
    static func apply(_ rec: GameRecommendation, to game: inout Game) -> Undo {
        let undo = Undo(engine: game.engine, settings: game.settings)
        var engine = game.engine ?? GameEngine()
        var text = rec.fileText
        func add(_ line: String) { text += (text.hasSuffix("\n") ? "" : "\n") + line + "\n" }
        if rec.wineVCRT == true { add("env.MADEIRA_WINE_VCRT = 1") }
        if rec.fastSync == false { add("env.MADEIRA_FASTSYNC = 0") }
        if let sem = rec.semaphoreFastPath { add("env.MADEIRA_FASTSYNC_SEM = \(sem ? 1 : 0)") }
        engine.config = text
        if let avx = rec.avx { engine.avx = avx ? true : nil }
        if let card = card(rec) { engine.gpuCard = card.id }
        game.engine = engine.isEmpty ? nil : engine
        var settings = game.settings ?? GameSettings()
        if let size = resolution(rec) { settings.resolution = size }
        if rec.launchMode == "desktop" { settings.dockDesktop = true }
        if let mine = ownSetup(for: rec) {
            if let mb = mine.swapMB { settings.swapMB = mb }
            if let coverage = mine.swapCoverage { settings.swapCoverage = coverage }
        }
        game.settings = settings.isEmpty ? nil : settings
        LogStore.shared.log("[tested-setup] \(game.name): \(rec.id) v\(rec.version) applied")
        return undo
    }

    struct Undo: Codable, Equatable {
        var engine: GameEngine?
        var settings: GameSettings?
    }

    private static func driveFileExists(_ windowsPath: String) -> Bool {
        let path = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard path.lowercased().hasPrefix("c:/") else { return false }
        let url = AppModel.driveC.appendingPathComponent(String(path.dropFirst(3)))
        let name = url.lastPathComponent.lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.contains { $0.lowercased() == name }
    }
}
