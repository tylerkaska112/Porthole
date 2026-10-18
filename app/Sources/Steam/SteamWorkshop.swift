// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// Steam Workshop: the community items of a game. This file holds what is read from Steam (browse, search, details, the account's subscriptions),
// how the files are recorded on disk the way Steam's own client records them, and the Web API calls. Downloading the files is SteamInstaller's workshop mode.
import CryptoKit
import Foundation

/// One Workshop item.
struct SteamWorkshopItem: Identifiable, Equatable {
    var id: UInt64
    var appID: Int
    var title: String
    var summary: String
    var previewURL: URL?
    var creator: UInt64?
    /// The app the item was made with (Portal 2 maps are made with its Authoring Tools, app 644).
    var creatorApp: Int?
    var fileSize: UInt64 = 0
    var subscriptions = 0
    var votesUp = 0
    var votesDown = 0
    var updated: Date?
    var tags: [String] = []
    /// The manifest of the item's files in the game's Workshop depot (0 when the item is not stored that way).
    var contentManifest: UInt64 = 0
    /// Items that are one plain file are served from a web address instead.
    var fileURL: URL?
    var filename: String?

    /// Share of the votes that are up, or nil when nobody has voted.
    var rating: Double? { votesUp + votesDown > 0 ? Double(votesUp) / Double(votesUp + votesDown) : nil }
    var canDownload: Bool { contentManifest != 0 || fileURL != nil }
}

/// What the account's subscription list says about one item (the answer to Steam's "enumerate subscribed files").
struct SteamSubscribedFile: Equatable {
    var id: UInt64
    var appID: Int
    var subscribed: Date?
    var updated: Date?
    var manifest: UInt64
    var size: UInt64
}

enum SteamWorkshopSort: String, CaseIterable, Identifiable {
    case trending, newest, popular, topRated
    var id: String { rawValue }
    var title: String { switch self { case .trending: "Trending"; case .newest: "Newest"; case .popular: "Most subscribed"; case .topRated: "Top rated" } }
    /// EPublishedFileQueryType: 3 ranked by trend, 1 by publication date, 9 by total unique subscriptions, 11 by votes up; 12 is a text search.
    var queryType: Int { switch self { case .trending: 3; case .newest: 1; case .popular: 9; case .topRated: 11 } }
    static let searchQueryType = 12
}

enum SteamWorkshopParser {
    /// `publishedfiledetails` of a QueryFiles / GetDetails answer. Entries Steam could not find (result other than 1) are left out.
    static func items(_ reply: [String: Any], appID: Int) -> [SteamWorkshopItem] {
        let list = (reply["publishedfiledetails"] as? [[String: Any]]) ?? []
        return list.compactMap { item(from: $0, appID: appID) }
    }

    static func item(from node: [String: Any], appID: Int) -> SteamWorkshopItem? {
        if let result = SteamJSON.int(node["result"]), result != 1 { return nil }
        guard let idText = SteamJSON.string(node["publishedfileid"]), let id = UInt64(idText) else { return nil }
        var item = SteamWorkshopItem(id: id, appID: (SteamJSON.int(node["consumer_appid"]) ?? SteamJSON.int(node["consumer_app_id"])).flatMap { $0 > 0 ? $0 : nil } ?? appID,
                                     title: SteamJSON.string(node["title"]) ?? "Item \(id)", summary: summary(node))
        item.previewURL = SteamJSON.string(node["preview_url"]).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        item.creator = SteamJSON.string(node["creator"]).flatMap { UInt64($0) }
        item.creatorApp = (SteamJSON.int(node["creator_appid"]) ?? SteamJSON.int(node["creator_app_id"])).flatMap { $0 > 0 ? $0 : nil }
        item.fileSize = SteamJSON.string(node["file_size"]).flatMap { UInt64($0) } ?? 0
        item.subscriptions = SteamJSON.int(node["subscriptions"]) ?? SteamJSON.int(node["lifetime_subscriptions"]) ?? 0
        if let votes = node["vote_data"] as? [String: Any] {
            item.votesUp = SteamJSON.int(votes["votes_up"]) ?? 0
            item.votesDown = SteamJSON.int(votes["votes_down"]) ?? 0
        }
        item.updated = SteamJSON.double(node["time_updated"]).map { Date(timeIntervalSince1970: $0) }
        item.tags = ((node["tags"] as? [[String: Any]]) ?? []).compactMap { SteamJSON.string($0["display_name"]) ?? SteamJSON.string($0["tag"]) }
        item.contentManifest = SteamJSON.string(node["hcontent_file"]).flatMap { UInt64($0) } ?? 0
        item.fileURL = SteamJSON.string(node["file_url"]).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        item.filename = SteamJSON.string(node["filename"]).flatMap { $0.isEmpty ? nil : $0 }
        return item
    }

    /// The short description, or the long one without its BBCode tags, cut to a few lines.
    static func summary(_ node: [String: Any]) -> String {
        let raw = SteamJSON.string(node["short_description"]).flatMap { $0.isEmpty ? nil : $0 } ?? SteamJSON.string(node["file_description"]) ?? SteamJSON.string(node["description"]) ?? ""
        let plain = raw.replacingOccurrences(of: "\\[/?[A-Za-z0-9*=#:_./ \"'-]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.count > 400 ? String(plain.prefix(400)) + "\u{2026}" : plain
    }

    /// CMsgClientUCMEnumerateUserSubscribedFilesWithUpdatesResponse: 1 eresult, 2 repeated {1 id (fixed64), 2 subscribed (fixed32), 3 appid, 4 content (fixed64),
    /// 5 size, 6 last updated (fixed32), 7 is depot content}, 3 total.
    static func subscribed(from body: Data) -> Result<(files: [SteamSubscribedFile], total: Int), SteamContentError> {
        guard let fields = PBFields(body) else { return .failure(SteamContentError(message: "Steam's list of subscribed items could not be read.")) }
        let code = fields.int(1) ?? 2
        guard code == 1 else { return .failure(SteamContentError(message: "Steam would not list the subscribed items (error \(code)).")) }
        let files = fields.messages(2).compactMap { entry -> SteamSubscribedFile? in
            guard let id = entry.uint(1), id != 0 else { return nil }
            return SteamSubscribedFile(id: id, appID: Int(entry.uint(3) ?? 0), subscribed: entry.uint(2).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                                       updated: entry.uint(6).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                                       manifest: entry.uint(4) ?? 0, size: entry.uint(5) ?? 0)
        }
        return .success((files, Int(fields.uint(3) ?? UInt64(files.count))))
    }
}

/// Steam's record of a game's Workshop items on disk: `steamapps/workshop/appworkshop_<app>.acf`, the files in `steamapps/workshop/content/<app>/<item>/`.
enum SteamWorkshopFiles {
    struct Installed: Equatable {
        var id: UInt64
        var size: UInt64
        var manifest: UInt64
        var updated: Date?
        /// For a single-file item (a Portal 2 map): its UGC handle. Steam's client records such an item with manifest -1 and this as `ugchandle`; without it the client thinks
        /// the item changed, marks the app "needs update" and fetches the file itself (and cleans away what the app put in its finished-download cache). 0 = a depot item.
        var ugcHandle: UInt64 = 0
    }

    static func contentFolder(appID: Int, steamApps: URL) -> URL { steamApps.appendingPathComponent("workshop/content/\(appID)", isDirectory: true) }
    static func itemFolder(appID: Int, item: UInt64, steamApps: URL) -> URL { contentFolder(appID: appID, steamApps: steamApps).appendingPathComponent(String(item), isDirectory: true) }
    static func recordURL(appID: Int, steamApps: URL) -> URL { steamApps.appendingPathComponent("workshop/appworkshop_\(appID).acf") }

    /// The items the record lists as installed.
    static func installed(appID: Int, steamApps: URL) -> [UInt64: Installed] {
        guard let text = try? String(contentsOf: recordURL(appID: appID, steamApps: steamApps), encoding: .utf8), let root = SteamVDF.parse(text),
              let node = root["appworkshop"] as? [String: Any], let items = node["workshopitemsinstalled"] as? [String: Any] else { return [:] }
        var found: [UInt64: Installed] = [:]
        for (key, value) in items {
            guard let id = UInt64(key), let entry = value as? [String: Any] else { continue }
            found[id] = Installed(id: id, size: (entry["size"] as? String).flatMap { UInt64($0) } ?? 0, manifest: (entry["manifest"] as? String).flatMap { UInt64($0) } ?? 0,
                                  updated: (entry["timeupdated"] as? String).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) })
        }
        // The details block (Steam's client writes it too) says which items are single files.
        if let details = node["workshopitemdetails"] as? [String: Any] {
            for (key, value) in details {
                guard let id = UInt64(key), found[id] != nil, let entry = value as? [String: Any], let handle = (entry["ugchandle"] as? String).flatMap({ UInt64($0) }), handle != 0 else { continue }
                found[id]?.ugcHandle = handle
            }
        }
        return found
    }

    // MARK: Valve's finished-download cache for single-file items

    /// A single-file item (a Portal 2 map) is fetched by the game through Steam's client by its UGC handle. The client keeps a finished download in
    /// `userdata/<account>/ugc/referenced/<handle>/` as the file plus a `data.vdf` (filename, app, creator, sha1), and asks Steam's content server only when that folder is missing.
    /// Where the client cannot reach the content server from inside the game (seen on one iPad), putting the file the app downloaded itself in that folder is what lets the game open it.
    static func referencedFolder(steamRoot: URL, account: String, handle: UInt64) -> URL {
        steamRoot.appendingPathComponent("userdata/\(account)/ugc/referenced/\(handle)", isDirectory: true)
    }

    /// The text of `data.vdf`, byte for byte what Valve's client writes.
    static func ugcDataText(filename: String, appID: Int, creator: UInt64, sha1: String) -> String {
        "\"\"\n{\n\t\"filename\"\t\t\"\(filename)\"\n\t\"appid\"\t\t\"\(appID)\"\n\t\"creator\"\t\t\"\(creator)\"\n\t\"sha1\"\t\t\"\(sha1)\"\n}\n"
    }

    static func sha1Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the folder already holds this file (so nothing needs doing).
    static func isSeeded(filename: String, handle: UInt64, steamRoot: URL, account: String) -> Bool {
        let folder = referencedFolder(steamRoot: steamRoot, account: account, handle: handle)
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("data.vdf").path) && fm.fileExists(atPath: folder.appendingPathComponent(filename).path)
    }

    /// Copies `file` (the item's file, `filename` relative to the item, like "mymaps/1.bsp") into Valve's finished-download cache. False when nothing was written.
    @discardableResult
    static func seedReferenced(file: URL, filename: String, handle: UInt64, appID: Int, creator: UInt64, steamRoot: URL, account: String) -> Bool {
        guard handle != 0, account != "0", !filename.contains(".."), let sha1 = sha1Hex(of: file) else { return false }
        let fm = FileManager.default
        let folder = referencedFolder(steamRoot: steamRoot, account: account, handle: handle)
        let target = folder.appendingPathComponent(filename)
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: file, to: target)
            try Data(ugcDataText(filename: filename, appID: appID, creator: creator, sha1: sha1).utf8).write(to: folder.appendingPathComponent("data.vdf"), options: .atomic)
            return true
        } catch { return false }
    }

    /// The text of the record for these items.
    static func recordText(appID: Int, items: [Installed], subscribedBy: String, now: Date = Date()) -> String {
        func q(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let stamp = String(Int(now.timeIntervalSince1970))
        var lines = ["\"AppWorkshop\"", "{", "\t\"appid\"\t\t\(q(String(appID)))", "\t\"SizeOnDisk\"\t\t\(q(String(items.reduce(0) { $0 + $1.size })))",
                     "\t\"NeedsUpdate\"\t\t\"0\"", "\t\"NeedsDownload\"\t\t\"0\"", "\t\"TimeLastUpdated\"\t\t\(q(stamp))", "\t\"TimeLastAppRan\"\t\t\"0\"",
                     "\t\"WorkshopItemsInstalled\"", "\t{"]
        let sorted = items.sorted { $0.id < $1.id }
        for item in sorted {
            lines += ["\t\t\(q(String(item.id)))", "\t\t{", "\t\t\t\"size\"\t\t\(q(String(item.size)))",
                      "\t\t\t\"timeupdated\"\t\t\(q(String(Int((item.updated ?? now).timeIntervalSince1970))))", "\t\t\t\"manifest\"\t\t\(q(String(item.manifest)))", "\t\t}"]
        }
        lines += ["\t}", "\t\"WorkshopItemDetails\"", "\t{"]
        for item in sorted {
            let updated = String(Int((item.updated ?? now).timeIntervalSince1970))
            // A single-file item is written the way Steam's client writes it: manifest -1 and the UGC handle.
            let single = item.ugcHandle != 0
            lines += ["\t\t\(q(String(item.id)))", "\t\t{", "\t\t\t\"manifest\"\t\t\(q(single ? "-1" : String(item.manifest)))"]
            if single { lines.append("\t\t\t\"ugchandle\"\t\t\(q(String(item.ugcHandle)))") }
            lines += ["\t\t\t\"timeupdated\"\t\t\(q(updated))",
                      "\t\t\t\"timetouched\"\t\t\(q(stamp))", "\t\t\t\"subscribedby\"\t\t\(q(subscribedBy))",
                      "\t\t\t\"latest_timeupdated\"\t\t\(q(updated))", "\t\t\t\"latest_manifest\"\t\t\(q(single ? "-1" : String(item.manifest)))", "\t\t}"]
        }
        lines += ["\t}", "}", ""]
        return lines.joined(separator: "\n")
    }

    /// Adds or replaces one item in the record (creating it if there is none).
    static func record(_ item: Installed, appID: Int, steamApps: URL, subscribedBy: String) {
        var all = installed(appID: appID, steamApps: steamApps)
        all[item.id] = item
        write(Array(all.values), appID: appID, steamApps: steamApps, subscribedBy: subscribedBy)
    }

    /// Deletes an item's files and takes it out of the record.
    static func remove(item: UInt64, appID: Int, steamApps: URL, subscribedBy: String) {
        try? FileManager.default.removeItem(at: itemFolder(appID: appID, item: item, steamApps: steamApps))
        var all = installed(appID: appID, steamApps: steamApps)
        all[item] = nil
        write(Array(all.values), appID: appID, steamApps: steamApps, subscribedBy: subscribedBy)
    }

    private static func write(_ items: [Installed], appID: Int, steamApps: URL, subscribedBy: String) {
        let url = recordURL(appID: appID, steamApps: steamApps)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? recordText(appID: appID, items: items, subscribedBy: subscribedBy).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Bytes under a folder.
    static func folderSize(_ url: URL) -> UInt64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += UInt64(values?.fileSize ?? 0) }
        }
        return total
    }
}

// MARK: - Web API

extension SteamAccount {
    /// A page of a game's Workshop items. `search` empty = the chosen ranking, else a text search. Pages start at 1.
    func workshopQuery(appID: Int, sort: SteamWorkshopSort, search: String, page: Int, perPage: Int = 20,
                       completion: @escaping (Result<(items: [SteamWorkshopItem], total: Int), SteamAPIError>) -> Void) {
        var input: [String: Any] = ["query_type": search.isEmpty ? sort.queryType : SteamWorkshopSort.searchQueryType, "page": page, "numperpage": perPage, "appid": appID,
                                    "filetype": 0, "return_vote_data": true, "return_tags": true, "return_short_description": true, "return_details": true,
                                    "return_metadata": false, "strip_description_bbcode": true]
        if !search.isEmpty { input["search_text"] = search }
        withToken { [weak self] token in
            self?.api.call("IPublishedFileService", "QueryFiles", post: false, input: input, accessToken: token) { result in
                completion(result.map { (SteamWorkshopParser.items($0, appID: appID), SteamJSON.int($0["total"]) ?? 0) })
            }
        } failure: { completion(.failure($0)) }
    }

    /// Details of known items (titles, pictures and the address or manifest of their files). Steam's public details call: it needs no sign-in,
    /// and the user-token one (IPublishedFileService/GetDetails) answers 401 to this app's token.
    func workshopDetails(ids: [UInt64], appID: Int, completion: @escaping (Result<[SteamWorkshopItem], SteamAPIError>) -> Void) {
        guard !ids.isEmpty else { completion(.success([])); return }
        guard let url = URL(string: "\(SteamAPI.host)/ISteamRemoteStorage/GetPublishedFileDetails/v1/") else { completion(.failure(.unexpected("bad URL"))); return }
        var form = "itemcount=\(ids.count)"
        for (index, id) in ids.enumerated() { form += "&publishedfileids%5B\(index)%5D=\(id)" }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(form.utf8)
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Porthole/1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        api.transport.send(request) { result in
            let outcome: Result<[SteamWorkshopItem], SteamAPIError>
            switch result {
            case .failure(let error): outcome = .failure(.unreachable(error.localizedDescription))
            case .success(let reply): outcome = SteamAPI.interpret(reply).map { SteamWorkshopParser.items($0, appID: appID) }
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Subscribes the account to an item (or unsubscribes). Steam then lists it for the game, in this app and in Steam itself.
    func workshopSubscribe(id: UInt64, appID: Int, subscribe: Bool, completion: @escaping (Result<Void, SteamAPIError>) -> Void) {
        let input: [String: Any] = ["publishedfileid": String(id), "list_type": 1, "appid": appID, "notify_client": false]
        withToken { [weak self] token in
            self?.api.call("IPublishedFileService", subscribe ? "Subscribe" : "Unsubscribe", post: true, input: input, accessToken: token) { result in
                completion(result.map { _ in () })
            }
        } failure: { completion(.failure($0)) }
    }

    private func withToken(_ run: @escaping (String) -> Void, failure: @escaping (SteamAPIError) -> Void) {
        accessToken(forceRefresh: false) { result in
            switch result {
            case .success(let token): run(token)
            case .failure(let error): failure(error)
            }
        }
    }
}
