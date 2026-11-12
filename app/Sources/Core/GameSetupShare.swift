// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// Share a game's setup (the idea is Madeira's "Share Setup", app/Madeira/GameSetupShare.swift): one game's settings in a file or a line of text for a chat, and
// applying one to a game in a tap. It holds what makes a game run well here (launch arguments, per-game settings, engine choices and lines, controller and touch
// binds), never the program's path, accounts or anything of the person's. Applying shows what it holds first and replaces the game's settings with it.
import Foundation

struct SharedSetup: Codable, Equatable {
    var format = 1
    var name: String
    var programName: String           // the program's file name, to say which game it was made for
    var steamAppID: Int?
    var args: String = ""
    var settings: GameSettings?
    var inDesktop: Bool?
    var engine: GameEngine?
    var bindSets: [BindSet]?
    var activeBindSetIndex: Int?
}

enum GameSetupShare {
    static let fileExtension = "portholesetup"
    private static let prefix = "porthole-setup1:"

    /// What a game would share.
    static func make(from game: Game) -> SharedSetup {
        var engine = game.engine
        engine?.padAuto = nil                     // what automatic mode learned on this device
        if engine?.isEmpty == true { engine = nil }
        let sets = game.bindSets.map { $0.map { var s = $0; s.remoteID = nil; s.downloadedFrom = nil; return s } }
        let active = game.activeBindSetID.flatMap { id in game.bindSets?.firstIndex { $0.id == id } }
        return SharedSetup(name: game.name, programName: game.exe.split(separator: "\\").last.map(String.init) ?? game.exe,
                           steamAppID: game.steamAppID.flatMap { $0 > 0 ? $0 : nil }, args: game.args,
                           settings: game.settings?.isEmpty == true ? nil : game.settings, inDesktop: game.inDesktop,
                           engine: engine, bindSets: sets?.isEmpty == true ? nil : sets, activeBindSetIndex: active)
    }

    /// A one-line text: easy to paste into a chat.
    static func text(_ setup: SharedSetup) -> String? {
        guard let json = try? JSONEncoder().encode(setup),
              let packed = try? (json as NSData).compressed(using: .zlib) else { return nil }
        return prefix + (packed as Data).base64EncodedString()
    }

    /// A file in the temporary folder, to hand to the share sheet.
    static func file(_ setup: SharedSetup) -> URL? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(setup) else { return nil }
        let safe = String(setup.name.map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : "_" }).trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((safe.isEmpty ? "Game" : safe) + " setup." + fileExtension)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    /// A setup from pasted text or the contents of a file; nil when it is neither.
    static func parse(_ raw: String) -> SharedSetup? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: prefix) {
            // The text may be wrapped over several lines by a chat, or followed by other words: take more pieces until it reads as a setup.
            let pieces = trimmed[range.upperBound...].split(whereSeparator: \.isWhitespace)
            var body = ""
            for piece in pieces.prefix(60) {
                body += piece
                if let packed = Data(base64Encoded: body), let json = try? (packed as NSData).decompressed(using: .zlib), let setup = decode(json as Data) { return setup }
            }
            return nil
        }
        return decode(Data(trimmed.utf8))
    }

    static func parse(file url: URL) -> SharedSetup? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 2 << 20,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8).flatMap(parse)
    }

    private static func decode(_ data: Data) -> SharedSetup? {
        guard let setup = try? JSONDecoder().decode(SharedSetup.self, from: data), setup.format == 1 else { return nil }
        return setup
    }

    /// The lines the apply sheet shows: everything the setup will put on the game, engine lines in full.
    static func summary(_ setup: SharedSetup) -> [String] {
        var out: [String] = []
        if !setup.args.isEmpty { out.append("Launch options: \(setup.args)") }
        if let s = setup.settings {
            if let v = s.powerMode { out.append("Power mode: \(PowerMode(rawValue: v)?.title ?? String(v))") }
            if let v = s.resolution { out.append("Resolution: \(v)") }
            if let v = s.swapMB { out.append("Swap: \(v) MB") }
            if let v = s.vramMB { out.append("Video memory: \(v) MB") }
            if let v = s.audioCushionMs { out.append("Audio buffer: \(v) ms") }
            if let v = s.preciseMath { out.append("Precise math: \(v ? "on" : "off")") }
            if let v = s.dockDesktop { out.append("Desktop window: \(v ? "on" : "off")") }
            if let v = s.lookSensitivity { out.append("Look speed: \(String(format: "%.2g", v))") }
        }
        if setup.inDesktop == true { out.append("Run on Wine's desktop") }
        if let e = setup.engine {
            if let v = e.avx { out.append("AVX and AVX2: \(v ? "on" : "off")") }
            if let v = e.cpuCount { out.append("CPU cores reported: \(v)") }
            if let v = e.anisotropy { out.append("Direct3D 9 anisotropic filtering: \(v)\u{00D7}") }
            if let v = e.reducedX87 { out.append("Reduced-precision x87: \(v ? "on" : "off")") }
            if let v = e.largeReservations { out.append("Large memory reservations: \(v ? "on" : "off")") }
            if let v = e.workDir { out.append("Working folder: \(v)") }
            if let v = e.controllerMode { out.append("Controller: \(v)") }
            if e.padRemap?.isEmpty == false { out.append("Remapped controller buttons") }
            if e.binds?.isEmpty == false { out.append("Controller buttons for keyboard and mouse mode") }
            if let a = e.padAssist, !a.isOff { out.append("Gyro aim / turbo") }
            if let config = e.config?.trimmingCharacters(in: .whitespacesAndNewlines), !config.isEmpty {
                out.append("Engine lines:")
                out += config.split(whereSeparator: \.isNewline).map { "    " + $0 }
            }
        }
        if let sets = setup.bindSets, !sets.isEmpty { out.append("\(sets.count) saved set(s) of controls: " + sets.map(\.name).joined(separator: ", ")) }
        return out.isEmpty ? ["Nothing but the defaults"] : out
    }

    /// The game with the setup put on it. The program, accounts and play history stay; bind sets get fresh ids.
    static func applied(_ setup: SharedSetup, to game: Game) -> Game {
        var g = game
        g.args = setup.args
        g.settings = setup.settings
        g.inDesktop = setup.inDesktop
        var engine = setup.engine
        engine?.padAuto = nil
        g.engine = engine
        let sets = (setup.bindSets ?? []).map { set -> BindSet in var s = set; s.id = UUID(); s.remoteID = nil; s.downloadedFrom = nil; return s }
        g.bindSets = sets.isEmpty ? nil : sets
        g.activeBindSetID = setup.activeBindSetIndex.flatMap { $0 < sets.count ? sets[$0].id : nil }
        return g
    }
}
