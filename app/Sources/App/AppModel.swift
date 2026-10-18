// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import SwiftUI

/// One library entry. `exe` is a WINDOWS path inside the prefix, e.g. C:\Factorio_2.0.77\bin\x64\factorio.exe
/// (a backslash path also makes the runtime pick the ARM64EC DLL set for x64 games).
struct Game: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var exe: String
    var args: String = ""
    /// Steam app whose artwork the card shows. nil = not looked up yet; 0 = looked up, nothing found.
    var steamAppID: Int?
    /// Set for games downloaded through the Steam screen: the app Valve's client starts for us (Madeira Dock), which checks your licence.
    var dockAppID: Int?
    /// true = run the program directly instead of through Steam.
    var launchDirect: Bool?
    var lastPlayed: Date?
    var playSeconds: Double?
    /// Per-game overrides of the global settings (nil field = use the global one).
    var settings: GameSettings?
    /// On-screen controls for this game; nil = standard (keyboard and mouse helpers).
    var controls: ControlLayout?
    /// true = run on Wine's desktop display, so ordinary Windows windows (installers, launchers, tools) are drawn.
    var inDesktop: Bool?
    /// A one-off installer run (never stored in the library).
    var installer: Bool?
    /// This game's own requests of the engine (AVX, frame generation, its own madeira.cfg lines, controller mode ...); nil = none. See EngineOptions.swift.
    var engine: GameEngine?
    /// This game's saved sets of controls (controller binds and/or a touch layout) and the one in use; none in use = the game's own settings. See BindSets.swift.
    var bindSets: [BindSet]?
    var activeBindSetID: UUID?
    /// How this game's own settings were before "Use what works for others" was applied, to undo it (see RecommendedSettings.swift).
    var settingsUndo: RecommendedSettings.Undo?
    /// Set for a game installed from the Epic Games store (Epic/): its app name, the launch arguments its manifest lists, and its public art. A launch adds a
    /// fresh exchange code to the arguments (SessionController); the saved game never holds it.
    var epicAppName: String?
    var epicLaunchCommand: String?
    var epicArtworkURL: URL?
    var epicHeroURL: URL?
    /// Set for a game installed from GOG (Gog/): its product id and its picture.
    var gogID: Int?
    var gogArtURL: URL?
    /// Set for a game installed from itch.io (Itch/): its game id and its picture.
    var itchID: Int?
    var itchArtURL: URL?
    /// Set for a game installed from Amazon Games (Amazon/): its product id and its picture.
    var amazonID: String?
    var amazonArtURL: URL?
}

/// Settings a game can override. Every field is optional: nil means "use the global setting".
struct GameSettings: Codable, Equatable {
    var powerMode: Int?             // PowerMode.rawValue
    var keepModeWhenHot: Bool?
    var swapMB: Int?
    var swapCoverage: String?       // "" classic, "blocks", "wide"
    var vramMB: Int?
    var audioCushionMs: Int?
    var preciseMath: Bool?
    var dockDesktop: Bool?
    var lookSensitivity: Double?    // first-person look speed (screen points -> mouse counts)
    var resolution: String?         // DisplayResolution id ("1280x720", "screen720"); nil follows the app-wide setting
    var isEmpty: Bool { self == GameSettings() }
}

/// Which on-screen controls a game gets.
enum ControlLayout: String, Codable, CaseIterable, Identifiable {
    case standard, firstPerson
    var id: String { rawValue }
    var title: String { self == .standard ? "Standard (mouse and keys)" : "First person (look pad + sticks)" }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var games: [Game] = []
    let session = SessionController()

    nonisolated static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    nonisolated static var prefix: URL { documents.appendingPathComponent("wine") }
    nonisolated static var driveC: URL { prefix.appendingPathComponent("drive_c") }
    private var libraryURL: URL { Self.documents.appendingPathComponent("f4-library.json") }

    private init() {
        // Make the folder exist so the Files app shows it before the first launch; games are copied in here.
        try? FileManager.default.createDirectory(at: Self.driveC, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: libraryURL),
              let list = try? JSONDecoder().decode([Game].self, from: data) else { return }
        games = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(games) else { return }
        try? data.write(to: libraryURL, options: .atomic)
    }

    func add(exe rawExe: String, name: String? = nil, steamAppID: Int? = nil, dockAppID: Int? = nil) {
        var exe = rawExe.trimmingCharacters(in: .whitespacesAndNewlines)
        while exe.contains("\\\\") { exe = exe.replacingOccurrences(of: "\\\\", with: "\\") }   // collapse doubled backslashes
        guard !games.contains(where: { $0.exe.caseInsensitiveCompare(exe) == .orderedSame }) else { return }
        let parts = exe.split(separator: "\\").map(String.init)
        let fallback = parts.count >= 2 ? parts[parts.count - 2] : (parts.last ?? exe)
        games.append(Game(name: name ?? fallback, exe: exe, steamAppID: steamAppID, dockAppID: dockAppID))
        save()
    }

    /// Copies a picked installer into drive_c/Installers (spaces become underscores: program arguments are split at spaces) and returns the game to run.
    /// .msi files run through the 32-bit msiexec.
    func installerGame(from picked: URL) throws -> Game {
        let ext = picked.pathExtension.lowercased()
        guard ext == "exe" || ext == "msi" else { throw NSError(domain: "Installer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pick a .exe or .msi installer."]) }
        let clean = picked.lastPathComponent.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? String($0) : "_" }.joined()
        let dir = Self.driveC.appendingPathComponent("Installers", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(clean)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: picked, to: dest)
        let winPath = "C:\\Installers\\" + clean
        var g = Game(name: "Installer: " + clean, exe: ext == "msi" ? "C:\\windows\\syswow64\\msiexec.exe" : winPath)
        if ext == "msi" { g.args = "/i " + winPath }
        g.inDesktop = true; g.installer = true
        return g
    }

    /// Adds an installed Epic game to the library, or brings the one with this app name up to date.
    func upsertEpic(appName: String, title: String, exe: String, command: String, artwork: URL?, hero: URL?) {
        if let i = games.firstIndex(where: { $0.epicAppName == appName }) {
            games[i].exe = exe; games[i].epicLaunchCommand = command; games[i].epicArtworkURL = artwork; games[i].epicHeroURL = hero
        } else {
            var game = Game(name: title, exe: exe)
            game.epicAppName = appName; game.epicLaunchCommand = command; game.epicArtworkURL = artwork; game.epicHeroURL = hero
            games.append(game)
        }
        save()
    }

    func removeEpic(appName: String) {
        games.removeAll { $0.epicAppName == appName }
        save()
    }

    /// Adds an installed GOG game to the library, or brings the one with this id up to date.
    func upsertGog(id: Int, title: String, exe: String, args: String, art: URL?) {
        if let i = games.firstIndex(where: { $0.gogID == id }) {
            games[i].exe = exe; games[i].args = args; games[i].gogArtURL = art
        } else {
            var game = Game(name: title, exe: exe)
            game.args = args; game.gogID = id; game.gogArtURL = art
            games.append(game)
        }
        save()
    }

    /// Adds an installed itch.io game to the library, or brings the one with this id up to date.
    func upsertItch(id: Int, title: String, exe: String, art: URL?) {
        if let i = games.firstIndex(where: { $0.itchID == id }) {
            games[i].exe = exe; games[i].itchArtURL = art
        } else {
            var game = Game(name: title, exe: exe)
            game.itchID = id; game.itchArtURL = art
            games.append(game)
        }
        save()
    }

    func removeItch(id: Int) {
        games.removeAll { $0.itchID == id }
        save()
    }

    /// Adds an installed Amazon Games game to the library, or brings the one with this id up to date. `workDir` is the folder its fuel.json asks to start in (a C:\ path).
    func upsertAmazon(id: String, title: String, exe: String, args: String, workDir: String?, art: URL?) {
        if let i = games.firstIndex(where: { $0.amazonID == id }) {
            games[i].exe = exe; games[i].args = args; games[i].amazonArtURL = art
            if let workDir, games[i].engine?.workDir == nil { var e = games[i].engine ?? GameEngine(); e.workDir = workDir; games[i].engine = e }
        } else {
            var game = Game(name: title, exe: exe)
            game.args = args; game.amazonID = id; game.amazonArtURL = art
            if let workDir { var e = GameEngine(); e.workDir = workDir; game.engine = e }
            games.append(game)
        }
        save()
    }

    func removeAmazon(id: String) {
        games.removeAll { $0.amazonID == id }
        save()
    }

    func removeGog(id: Int) {
        games.removeAll { $0.gogID == id }
        save()
    }

    func update(_ game: Game, _ change: (inout Game) -> Void) {
        guard let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        change(&games[i]); save()
    }

    func recordPlay(_ game: Game, seconds: Double) {
        update(game) { $0.lastPlayed = Date(); $0.playSeconds = ($0.playSeconds ?? 0) + max(0, seconds) }
    }

    /// 32 or 64: read from the program's PE header (nil if unreadable).
    nonisolated static func peBits(windowsPath: String) -> Int? {
        guard let url = unixURL(forWindows: windowsPath) else { return nil }
        return peBits(file: url)
    }

    nonisolated static func peBits(file url: URL) -> Int? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let dos = try? h.read(upToCount: 0x40), dos.count == 0x40, dos[0] == 0x4D, dos[1] == 0x5A else { return nil }
        let off = UInt64(dos[0x3c]) | UInt64(dos[0x3d]) << 8 | UInt64(dos[0x3e]) << 16 | UInt64(dos[0x3f]) << 24
        guard (try? h.seek(toOffset: off)) != nil, let pe = try? h.read(upToCount: 6), pe.count == 6, pe[0] == 0x50, pe[1] == 0x45 else { return nil }
        switch Int(pe[4]) | Int(pe[5]) << 8 { case 0x14c: return 32; case 0x8664, 0xAA64: return 64; default: return nil }
    }

    /// Programs such as the Epic Games Launcher ship their own Microsoft ucrtbase.dll next to the exe. Windows ignores it (ucrtbase is a "known DLL"), but Wine
    /// loads the program's copy first and its entry point then runs as ARM code and crashes before the program starts. Rename those copies (reversible:
    /// ucrtbase.dll.f4off) so the built-in one is used. Looks in the install folder (Program Files/<vendor>/<app>) or the exe's own folder. Returns the renamed paths.
    nonisolated static func sidelineBundledUCRT(forExe windowsPath: String) -> [String] {
        guard let exe = unixURL(forWindows: windowsPath) else { return [] }
        let rel = exe.path.replacingOccurrences(of: driveC.path + "/", with: "").split(separator: "/").map(String.init)
        var root = exe.deletingLastPathComponent()
        if rel.count > 4, rel[0].hasPrefix("Program Files") { root = rel[1...2].reduce(driveC.appendingPathComponent(rel[0])) { $0.appendingPathComponent($1) } }
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var done: [String] = []
        for case let f as URL in walk where f.lastPathComponent.lowercased() == "ucrtbase.dll" {
            let off = f.appendingPathExtension("f4off")
            try? FileManager.default.removeItem(at: off)
            if (try? FileManager.default.moveItem(at: f, to: off)) != nil { done.append(f.path.replacingOccurrences(of: driveC.path, with: "C:")) }
            if done.count >= 40 { break }
        }
        return done
    }

    /// For the real Steam client (steam.exe): writes a small batch file next to drive_c and returns its Windows path, or nil for any other program.
    nonisolated static func steamClientScript(exe: String, extraArgs: String) -> String? {
        guard exe.lowercased().hasSuffix("\\steam.exe"), unixURL(forWindows: exe) != nil else { return nil }
        let dir = String(exe.dropLast("steam.exe".count))
        let extra = extraArgs.trimmingCharacters(in: .whitespaces)
        let bat = "@echo off\r\nstart \"\" \"C:\\windows\\sysnative\\services.exe\"\r\ncd /d \"\(dir)\"\r\n\"\(exe)\" -no-cef-sandbox -cef-disable-gpu -nocrashmonitor \(extra)\r\n"
        let url = driveC.appendingPathComponent("f4-steam.bat")
        guard (try? bat.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return "C:\\f4-steam.bat"
    }

    func setLaunchDirect(_ direct: Bool, for game: Game) {
        guard let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[i].launchDirect = direct
        save()
    }

    func setSteamAppID(_ id: Int?, for game: Game) {
        guard let i = games.firstIndex(where: { $0.id == game.id }), games[i].steamAppID != id else { return }
        games[i].steamAppID = id
        save()
    }

    func remove(_ game: Game) {
        games.removeAll { $0.id == game.id }
        save()
    }

    /// Windows path ("C:\\dir\\file.exe") for a file path relative to drive_c.
    nonisolated static func windowsPath(forRelative rel: String) -> String {
        "C:\\" + rel.split(separator: "/").joined(separator: "\\")
    }

    /// The file a Windows path points at inside drive_c (nil if it is not a C: path).
    nonisolated static func unixURL(forWindows path: String) -> URL? {
        guard path.count > 3, path.lowercased().hasPrefix("c:\\") else { return nil }
        let parts = path.dropFirst(3).split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        return parts.reduce(driveC) { $0.appendingPathComponent($1) }
    }

    /// Executables found under drive_c (Windows paths). Skips Wine's own tree and installers.
    /// iOS reports enumerated paths as /private/var/... while Documents is /var/..., so both sides are resolved first.
    nonisolated static func scanForExecutables() -> [String] {
        let root = driveC.resolvingSymlinksInPath()
        let skip: Set<String> = ["windows", "users", "programdata", "common files"]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(root.path + "/") else { continue }
            let rel = String(full.dropFirst(root.path.count + 1))
            let comps = rel.split(separator: "/").map { $0.lowercased() }
            if comps.count > 6 { walker.skipDescendants(); continue }
            if comps.count == 1, skip.contains(comps[0]) { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let file = url.lastPathComponent.lowercased()
            if file.hasPrefix("unins") || file.contains("crashpad") || file.contains("setup") { continue }
            found.append(windowsPath(forRelative: rel))
        }
        return found.sorted()
    }
}
