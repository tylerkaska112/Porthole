// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Finds a Steam library inside a folder a person picked on an external drive, and words what a scan found. Foundation only, so a host test can check it.
/// A library is a folder that holds `steamapps` (Steam on a PC calls it `SteamLibrary` or `Steam`; Porthole's own SSD folder is the library itself).
enum SteamLibraryFinder {
    /// Names Steam and its users give the folder that holds `steamapps`; looked at before any other folder.
    private static let usual = ["steamlibrary", "steam library", "steam", "steamlibrary2"]

    /// The folder to register: the picked folder itself when it holds `steamapps`, its parent when `steamapps` itself was picked, else the first folder one level down
    /// that holds `steamapps` (the usual names first). Nil when there is none.
    static func find(in picked: URL, fileManager fm: FileManager = .default) -> URL? {
        func isDirectory(_ url: URL) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue }
        func holdsSteamApps(_ url: URL) -> Bool { isDirectory(url.appendingPathComponent("steamapps", isDirectory: true)) }
        if holdsSteamApps(picked) { return picked }
        if picked.lastPathComponent.lowercased() == "steamapps", isDirectory(picked) { return picked.deletingLastPathComponent() }
        guard let names = try? fm.contentsOfDirectory(atPath: picked.path) else { return nil }
        let folders = names.filter { !$0.hasPrefix(".") }.sorted().prefix(200).map { picked.appendingPathComponent($0, isDirectory: true) }.filter(isDirectory)
        let preferred = folders.filter { usual.contains($0.lastPathComponent.lowercased()) }
        return (preferred + folders).first(where: holdsSteamApps)
    }

    /// What a scan did, in words for the person.
    static func summary(driveName: String, installed: Int, added: Int) -> (title: String, message: String) {
        func games(_ n: Int) -> String { n == 1 ? "1 game" : "\(n) games" }
        if added > 0 {
            return ("Added \(games(added)) from \(driveName)",
                    "They are in your Steam list now and start through Steam like any other. The files stay on the drive: keep it plugged in when you press Play.")
        }
        if installed > 0 {
            return ("No new games on \(driveName)", "\(games(installed)) from it \(installed == 1 ? "is" : "are") already in your Steam list.")
        }
        return ("No Steam games found on \(driveName)",
                "Porthole looks for a steamapps folder on the drive: the library Steam makes on a PC, or one Porthole made. If your games are in another folder, choose that folder instead.")
    }
}
