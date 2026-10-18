// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// The signed-in person's Steam friends, read only: who they are, whether they are online and what they are playing. Steam's Web API with the sign-in token the app already
// holds: IFriendsListService for the ids, ISteamUserOAuth/GetUserSummaries for names, pictures and state (a probe showed this works with the token and the usual
// GetPlayerSummaries does not), and IPlayerService/GetPlayerLinkDetails as a fallback that gives names and pictures but no state. Read only, on request.
import Foundation

struct SteamFriend: Identifiable, Equatable {
    var id: String                       // the 64-bit Steam id
    var name: String
    var avatarURL: URL?
    /// 0 offline, 1 online, 2 busy, 3 away, 4 snooze, 5 looking to trade, 6 looking to play.
    var state = 0
    var gameName: String?
    var gameID: Int?
    var lastLogoff: Date?
    var profileURL: URL?

    var isPlaying: Bool { gameName != nil || gameID != nil }
    var isOnline: Bool { state > 0 || isPlaying }

    /// "In Portal 2", "Online", "Away", or "Offline" with how long ago when known.
    func status(now: Date = Date()) -> String {
        if let gameName { return "In \(gameName)" }
        if isPlaying { return "In a game" }
        switch state {
        case 1: return "Online"
        case 2: return "Busy"
        case 3: return "Away"
        case 4: return "Snoozing"
        case 5: return "Looking to trade"
        case 6: return "Looking to play"
        default:
            guard let lastLogoff, lastLogoff > Date(timeIntervalSince1970: 86_400) else { return "Offline" }
            let seconds = max(0, now.timeIntervalSince(lastLogoff))
            if seconds < 3600 { return "Offline \u{00B7} \(max(1, Int(seconds / 60))) min ago" }
            if seconds < 86_400 { return "Offline \u{00B7} \(Int(seconds / 3600)) h ago" }
            return "Offline \u{00B7} \(Int(seconds / 86_400)) d ago"
        }
    }
}

enum SteamFriendsParser {
    /// The 64-bit ids of the people on the friends list proper (relationship 3): not blocked, ignored or pending ones.
    static func friendIDs(_ reply: [String: Any]) -> [String] {
        let entries = (((reply["friendslist"] as? [String: Any])?["friends"] as? [[String: Any]]) ?? (reply["friends"] as? [[String: Any]]) ?? [])
        return entries.filter { (SteamJSON.int($0["efriendrelationship"]) ?? SteamJSON.int($0["relationship"]) ?? 3) == 3 }
            .compactMap { SteamJSON.string($0["ulfriendid"]) ?? SteamJSON.string($0["steamid"]) }
    }

    /// `players` of ISteamUserOAuth/GetUserSummaries.
    static func friends(summaries reply: [String: Any]) -> [SteamFriend] {
        ((reply["players"] as? [[String: Any]]) ?? []).compactMap { node in
            guard let id = SteamJSON.string(node["steamid"]), let name = SteamJSON.string(node["personaname"]), !name.isEmpty else { return nil }
            let game = SteamJSON.string(node["gameextrainfo"]).flatMap { $0.isEmpty ? nil : $0 }
            let gameID = SteamJSON.string(node["gameid"]).flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            return SteamFriend(id: id, name: name, avatarURL: (SteamJSON.string(node["avatarmedium"]) ?? SteamJSON.string(node["avatar"])).flatMap(URL.init(string:)),
                               state: SteamJSON.int(node["personastate"]) ?? 0, gameName: game, gameID: gameID,
                               lastLogoff: SteamJSON.double(node["lastlogoff"]).map { Date(timeIntervalSince1970: $0) },
                               profileURL: SteamJSON.string(node["profileurl"]).flatMap(URL.init(string:)))
        }
    }

    /// The fallback: names and picture hashes, no state.
    static func friends(linkDetails reply: [String: Any]) -> [SteamFriend] {
        ((reply["accounts"] as? [[String: Any]]) ?? []).compactMap { account in
            guard let node = account["public_data"] as? [String: Any], let id = SteamJSON.string(node["steamid"]), let name = SteamJSON.string(node["persona_name"]), !name.isEmpty else { return nil }
            let hash = SteamJSON.string(node["sha_digest_avatar"]) ?? ""
            let avatar = hash.isEmpty ? nil : URL(string: "https://avatars.fastly.steamstatic.com/\(hash)_medium.jpg")
            return SteamFriend(id: id, name: name, avatarURL: avatar, profileURL: SteamJSON.string(node["profile_url"]).flatMap(URL.init(string:)))
        }
    }

    /// Playing first, then online (by name), then offline with the most recently seen first.
    static func sorted(_ list: [SteamFriend]) -> [SteamFriend] {
        func rank(_ f: SteamFriend) -> Int { f.isPlaying ? 0 : (f.isOnline ? 1 : 2) }
        return list.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if rank(a) == 2, a.lastLogoff != b.lastLogoff { return (a.lastLogoff ?? .distantPast) > (b.lastLogoff ?? .distantPast) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

extension SteamAccount {
    /// The friends with their state. The ids come from the friends list; names and state in groups of 100.
    func loadFriends(completion: @escaping (Result<(friends: [SteamFriend], hasState: Bool), SteamAPIError>) -> Void) {
        accessToken(forceRefresh: false) { [weak self] result in
            guard let self else { return }
            guard case .success(let token) = result else { if case .failure(let e) = result { completion(.failure(e)) }; return }
            self.api.call("IFriendsListService", "GetFriendsList", post: false, input: [:], accessToken: token) { list in
                switch list {
                case .failure(let error): completion(.failure(error))
                case .success(let reply):
                    let ids = SteamFriendsParser.friendIDs(reply)
                    guard !ids.isEmpty else { completion(.success(([], true))); return }
                    let groups = stride(from: 0, to: ids.count, by: 100).map { Array(ids[$0..<min($0 + 100, ids.count)]) }
                    var found: [SteamFriend] = [], failed = false, pending = groups.count
                    func finish() {
                        pending -= 1
                        guard pending == 0 else { return }
                        if failed || found.isEmpty { self.loadFriendsFallback(ids: ids, token: token, completion: completion) }
                        else { completion(.success((SteamFriendsParser.sorted(found), true))) }
                    }
                    for group in groups {
                        self.friendsGet("ISteamUserOAuth", "GetUserSummaries", version: 1, ["steamids": group.joined(separator: ",")], token) { r in
                            if case .success(let reply) = r { found += SteamFriendsParser.friends(summaries: reply) } else { failed = true }
                            finish()
                        }
                    }
                }
            }
        }
    }

    private func loadFriendsFallback(ids: [String], token: String, completion: @escaping (Result<(friends: [SteamFriend], hasState: Bool), SteamAPIError>) -> Void) {
        api.call("IPlayerService", "GetPlayerLinkDetails", post: false, input: ["steamids": Array(ids.prefix(100))], accessToken: token) { r in
            switch r {
            case .failure(let error): completion(.failure(error))
            case .success(let reply): completion(.success((SteamFriendsParser.sorted(SteamFriendsParser.friends(linkDetails: reply)), false)))
            }
        }
    }

    fileprivate func friendsGet(_ interface: String, _ method: String, version: Int, _ params: [String: String], _ token: String,
                                completion: @escaping (Result<[String: Any], SteamAPIError>) -> Void) {
        var query = "access_token=" + SteamJSON.formEncode(token)
        for (key, value) in params.sorted(by: { $0.key < $1.key }) { query += "&\(key)=" + SteamJSON.formEncode(value) }
        guard let url = URL(string: "\(SteamAPI.host)/\(interface)/\(method)/v\(version)/?\(query)") else { completion(.failure(.unexpected("bad URL"))); return }
        var request = URLRequest(url: url)
        request.setValue("Porthole/1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        api.transport.send(request) { result in
            let outcome: Result<[String: Any], SteamAPIError>
            switch result {
            case .failure(let error): outcome = .failure(.unreachable(error.localizedDescription))
            case .success(let reply): outcome = SteamAPI.interpret(reply)
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
