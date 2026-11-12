// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Keeps Steam's in-game overlay from loading. A game that links Steam's API (steam_api64.dll) finds the Steam client installed in the prefix, loads its steamclient64.dll, and that
/// loads gameoverlayrenderer64.dll into the game. The overlay hooks the game's graphics calls and looks for free executable memory next to each function it hooks; the engine only
/// allows executable memory inside its own JIT pool, so every one of those requests is refused and the search never ends: Hollow Knight: Silksong sat for minutes asking for a page
/// at every 4 KB step through 8 GB of address space (2 million refusals) while its main thread waited (log of 2026-10-07). The overlay is of no use on a phone, so its DLLs are renamed
/// (never deleted) before a game starts, and Steam carries on without it. This is OFF by default (the overlay is left alone): the hang was seen only with a wrong executable, so it is
/// not known to be the overlay's doing. The Engine option "Steam overlay" > Off turns it on; any other choice puts the DLLs back.
enum SteamOverlayBlock {
    static let suffix = ".porthole-off"
    private static let names = ["gameoverlayrenderer64.dll", "gameoverlayrenderer.dll"]

    /// The overlay is left alone unless the person switched it off (`env.PORTHOLE_STEAM_OVERLAY = 0`).
    static var allowed: Bool { EngineOptions.value("env.PORTHOLE_STEAM_OVERLAY") != "0" }

    static func apply(drive: URL, log: (String) -> Void = { _ in }) {
        let steam = drive.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: steam.path) else { return }
        let lower = Dictionary(files.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for name in names {
            let on = steam.appendingPathComponent(lower[name] ?? name), off = steam.appendingPathComponent(name + suffix)
            let hasOn = lower[name] != nil, hasOff = lower[name + suffix] != nil
            do {
                if allowed {
                    if hasOff && !hasOn { try FileManager.default.moveItem(at: off, to: steam.appendingPathComponent(name)); log("[steam-overlay] \(name) put back") }
                } else if hasOn {
                    if hasOff { try FileManager.default.removeItem(at: off) }            // an older copy from before a Steam update
                    try FileManager.default.moveItem(at: on, to: off)
                    log("[steam-overlay] \(name) set aside so the overlay cannot hook the game")
                }
            } catch { log("[steam-overlay] could not change \(name): \(ErrorText.plain(error))") }
        }
    }
}
