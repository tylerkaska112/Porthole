// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Recognises an online anti-cheat from the files a game ships, so the person is told before a large download (and on the game's page afterwards) why it will not play.
/// These run inside Windows as drivers or services Porthole's Windows does not have. Hub reports: Fall Guys (Easy Anti-Cheat, 2 reports, both broken), PUBG (BattlEye, ended
/// with code 0xDEADC0DE, the value BattlEye ends a game with). Only names that are specific to the anti-cheat count; a folder called "Client" or "Bin" never does.
enum EpicAntiCheat {
    /// The name of the anti-cheat these paths belong to, or nil. `paths` are file paths as a manifest or a folder listing gives them (either kind of separator).
    static func detect(paths: [String]) -> String? {
        var found: [String: Bool] = [:]
        for path in paths {
            let parts = path.lowercased().split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
            guard let file = parts.last else { continue }
            let folders = parts.dropLast()
            if folders.contains("easyanticheat") || folders.contains("easyanticheat_eos") || file.hasPrefix("easyanticheat") || file == "eac_launcher.exe" || file.hasPrefix("eaclauncher") { found["Easy Anti-Cheat"] = true }
            else if folders.contains("battleye") || file.hasPrefix("beservice") || file.hasPrefix("beclient") || file == "belauncher.exe" { found["BattlEye"] = true }
            else if file.hasPrefix("equ8") || folders.contains("equ8") { found["EQU8"] = true }
            else if file.hasPrefix("pbsvc") || file.hasPrefix("punkbuster") || folders.contains("punkbuster") { found["PunkBuster"] = true }
            else if file.hasPrefix("npggnt") || file == "gameguard.des" || folders.contains("gameguard") { found["GameGuard"] = true }
        }
        // A game with several lists them in a fixed order.
        let order = ["Easy Anti-Cheat", "BattlEye", "EQU8", "PunkBuster", "GameGuard"]
        let names = order.filter { found[$0] == true }
        return names.isEmpty ? nil : names.joined(separator: " and ")
    }

    /// What to tell the person.
    static func warning(_ name: String) -> String {
        "This game uses \(name). Anti-cheat of this kind does not run on Porthole, so online play will not work and the game may not start at all."
    }
}
