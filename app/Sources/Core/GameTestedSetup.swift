// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Madeira's tested setups (GameRecommendations.swift, taken from willfaust/Madeira): for about a hundred games, the engine lines and switches that were found to work on
/// their builds. Porthole never applies one by itself: a game's page shows it ("Madeira's tested setup") and the person chooses, with the previous engine lines kept for Undo.
/// Only what Porthole has a place for is applied; the rest is listed, so nothing is silently dropped.
enum GameTestedSetup {
    /// The setup for a game, or nil. The "standard" list (for games Madeira has no list for) is not offered.
    static func recommendation(for game: Game) -> GameRecommendation? {
        guard game.installer != true else { return nil }
        let id = game.dockAppID ?? game.steamAppID
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
