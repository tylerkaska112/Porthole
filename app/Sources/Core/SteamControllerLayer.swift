// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Steam's controller layer (the one 64-bit library, SDL3.dll, Steam Input needs): downloaded once and removed again from Settings > Stores > Steam. The Steam page offers the
/// download until it is on the device; after that it lives in Settings, like the Steam client.
@MainActor
final class SteamControllerLayer: ObservableObject {
    static let shared = SteamControllerLayer()

    @Published private(set) var installed = SteamSDL3.installed
    @Published private(set) var busy = false
    @Published private(set) var status: String?

    static let info = "Steam's own controller layer (Steam Input) needs a 64-bit library the Steam client files do not include. This downloads that one file, about 1.3 MB, from Valve's server and checks it against its known fingerprint before using it; nothing else is installed. Games such as Portal and Portal 2 read their controller through Steam Input. Remove puts the original file back."

    /// The layer can be offered: the Steam client's files are there for it to sit next to.
    var available: Bool { SteamSDL3.steamPresent }

    func refresh() { installed = SteamSDL3.installed }

    /// One line for the row.
    var subtitle: String {
        if busy { return status ?? "Working\u{2026}" }
        return status ?? (installed ? "Installed" : "Needed by games that take their controller from Steam, like Portal")
    }

    /// Downloads it, or removes it when it is there.
    func toggle() {
        guard !busy else { return }
        busy = true; status = "Starting\u{2026}"
        Task {
            do {
                if installed { try SteamSDL3.remove() } else { try await SteamSDL3.install { text in await MainActor.run { self.status = text } } }
                installed = SteamSDL3.installed
                status = nil
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
}
