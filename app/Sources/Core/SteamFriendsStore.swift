// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// The friends list the screens show. Read only, loaded when a screen asks for it and at most every 30 seconds; kept in memory only.
@MainActor
final class SteamFriendsStore: ObservableObject {
    static let shared = SteamFriendsStore()

    @Published private(set) var friends: [SteamFriend] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var loaded = false
    /// False when Steam only gave names and pictures (no online state).
    @Published private(set) var hasState = true

    private var lastLoad = Date.distantPast
    private let service = SteamService.shared

    func refresh(force: Bool = false) async {
        guard !loading, force || Date().timeIntervalSince(lastLoad) > 30 else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await service.friends()
            friends = result.friends; hasState = result.hasState; loaded = true; lastLoad = Date()
            SteamLog.event("[friends] \(result.friends.count) friends loaded" + (result.hasState ? "" : " (names only)"))
        } catch {
            self.error = SteamSignIn.message(error)
            loaded = true
        }
    }

    var playing: [SteamFriend] { friends.filter(\.isPlaying) }
    /// Friends who are in this Steam game right now.
    func playing(game appID: Int) -> [SteamFriend] { friends.filter { $0.gameID == appID } }
    var online: [SteamFriend] { friends.filter { $0.isOnline && !$0.isPlaying } }
    var offline: [SteamFriend] { friends.filter { !$0.isOnline } }
}
