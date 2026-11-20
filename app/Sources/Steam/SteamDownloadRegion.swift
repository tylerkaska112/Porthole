// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Steam's "download region": which group of Valve's download servers a game comes from. Steam's server directory takes a region number (`cell_id`); by default Steam picks one from where
/// the connection seems to be, and a different one can be faster in special cases (a distant default, a provider that routes badly). Foundation only, so a host test can check it.
enum SteamDownloadRegion {
    struct Region: Equatable { let cell: Int; let name: String }

    /// 0 (or nothing saved) is Steam's own choice.
    static let key = "f4.steamDownloadCell"

    /// The regions that have download servers of their own, with the city their servers are in (read from the server names Steam's directory lists for each number, 2026-11-13).
    static let all: [Region] = [
        Region(cell: 63, name: "Washington DC"), Region(cell: 50, name: "Atlanta"), Region(cell: 65, name: "Dallas"), Region(cell: 1, name: "Chicago"),
        Region(cell: 64, name: "Los Angeles"), Region(cell: 31, name: "Seattle"),
        Region(cell: 25, name: "S\u{00E3}o Paulo"), Region(cell: 116, name: "Buenos Aires"), Region(cell: 117, name: "Santiago"), Region(cell: 118, name: "Lima"),
        Region(cell: 4, name: "London"), Region(cell: 14, name: "Paris"), Region(cell: 15, name: "Amsterdam"), Region(cell: 5, name: "Frankfurt"),
        Region(cell: 66, name: "Stockholm"), Region(cell: 38, name: "Warsaw"), Region(cell: 92, name: "Vienna"),
        Region(cell: 26, name: "Johannesburg"),
        Region(cell: 32, name: "Tokyo"), Region(cell: 33, name: "Hong Kong"), Region(cell: 35, name: "Singapore"), Region(cell: 52, name: "Sydney"),
    ]

    /// The number the person chose, or nil for Steam's own choice. A number that is not in the list is ignored.
    static func chosen(_ defaults: UserDefaults = .standard) -> Int? {
        let cell = defaults.integer(forKey: key)
        return all.contains { $0.cell == cell } ? cell : nil
    }

    static func name(forCell cell: Int) -> String? { all.first { $0.cell == cell }?.name }
}
