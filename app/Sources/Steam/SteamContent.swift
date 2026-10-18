// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// What a Steam download needs to know: which files (depots) an app has, their keys and manifests, and where the content
// servers are. `SteamContentBackend` is the seam: `SteamCMBackend` talks to Steam, the tests use a stand-in.
import Foundation

struct SteamContentError: Error, Equatable, CustomStringConvertible {
    var message: String
    /// The account does not own this app or depot (Steam answered "access denied").
    var notOwned = false
    var description: String { message }
}

// MARK: - App information

struct SteamDepot: Equatable {
    var id: Int
    var name = ""
    var osList: [String] = []
    var osArch: String?
    var language: String?
    var manifest: UInt64?
    var size: UInt64?
    /// What the depot takes to download (compressed); `size` is what it takes on disk.
    var download: UInt64?
    var fromApp: Int?
    var dlcApp: Int?
    var optionalDLC = false
    /// The depot's manifest on every branch Steam lists it for (the public one is also in `manifest`, `size` and `download` above).
    var branchManifests: [String: SteamDepotManifestEntry] = [:]
    /// Manifests of branches that need a password (a private beta): the id is encrypted with the branch's key, which Steam gives for the right password.
    var encryptedManifests: [String: SteamEncryptedManifest] = [:]
}

struct SteamDepotManifestEntry: Equatable {
    var gid: UInt64
    var size: UInt64?
    var download: UInt64?
}

struct SteamEncryptedManifest: Equatable {
    /// The manifest id, encrypted (raw bytes, decoded from the hex Steam writes).
    var gid: Data
    var size: UInt64?
    var download: UInt64?
}

/// A version of a game Steam offers: "public" (the normal one) or a beta such as "beta", "experimental" or "previous_version".
struct SteamBranch: Equatable, Identifiable {
    var name: String
    var buildID: String?
    var description = ""
    /// The branch needs a password to be seen or installed.
    var passwordRequired = false
    var updated: Date?
    var id: String { name }
    static let publicName = "public"
}

/// One way Steam says a game can be started (config/launch in its product information).
struct SteamLaunchOption: Codable, Hashable {
    var executable: String
    var arguments: String = ""
    var type: String = ""
    var oslist: String = ""
    var description: String = ""
    /// The entry's number under config/launch, which is what Valve's client is asked for ("launch option N"). Not every app starts at 0:
    /// Factorio's Windows entries are 1 and 2. nil = not known (a library list saved before the number was kept).
    var key: Int? = nil
    /// "32" or "64" when the entry names a processor width, else empty.
    var osarch: String = ""

    init(executable: String, arguments: String = "", type: String = "", oslist: String = "", description: String = "", key: Int? = nil, osarch: String = "") {
        self.executable = executable; self.arguments = arguments; self.type = type; self.oslist = oslist; self.description = description
        self.key = key; self.osarch = osarch
    }

    // Saved lists from before `key` and `osarch` existed still load, with the number marked unknown (not 0: that would look like an answer).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        oslist = try c.decodeIfPresent(String.self, forKey: .oslist) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        key = try c.decodeIfPresent(Int.self, forKey: .key)
        osarch = try c.decodeIfPresent(String.self, forKey: .osarch) ?? ""
    }

    /// The launch option to ask Valve's client for when starting a game through Steam: the lowest-numbered ordinary entry for Windows that suits a 64-bit
    /// client (no processor width, or 64). 0 when no entry suits (what the host always asked for before it could be told). nil when it cannot be told:
    /// no list, or the list was saved before the numbers were kept, so the caller should fetch it fresh.
    static func dockDefaultKey(in options: [SteamLaunchOption]) -> Int? {
        guard !options.isEmpty else { return nil }
        let ordinary = options.filter { ["", "default"].contains($0.type.lowercased()) }
        let windows = ordinary.filter { $0.oslist.isEmpty || $0.oslist.contains("windows") }
        let suitable = windows.filter { $0.osarch.isEmpty || $0.osarch == "64" }
        if suitable.isEmpty { return 0 }
        if suitable.contains(where: { $0.key == nil }) { return nil }
        return suitable.compactMap(\.key).min()
    }
}

struct SteamAppInfo: Equatable {
    var appid: Int
    var name: String
    var installDirectory: String?
    var buildID: String?
    var depots: [SteamDepot]
    /// "game", "dlc", "tool", "demo", "music", ... (common/type), lowercased; empty when Steam does not say.
    var type: String = ""
    var launches: [SteamLaunchOption] = []
    /// Every branch of the game, "public" first, the rest by name.
    var branches: [SteamBranch] = []
    /// The DLC apps whose files are part of this game's depots (what the install can add), by app id.
    var dlcApps: [Int] = []
    /// The DLC apps the game lists as its own (extended/listofdlc), which can include DLC without files of its own.
    var listedDLC: [Int] = []
    /// The depot the app's Workshop items are stored in (`depots/workshopdepot`); nil means the app's own id.
    var workshopDepot: Int?
}

enum SteamAppInfoParser {
    /// Reads the text KeyValues an app's product info arrives as.
    static func parse(_ data: Data, appid: Int) -> SteamAppInfo? {
        var bytes = data
        while bytes.last == 0 { bytes.removeLast() }
        guard let text = String(data: bytes, encoding: .utf8), let root = SteamVDF.parse(text) else { return nil }
        let app = (root["appinfo"] as? [String: Any]) ?? root
        let common = app["common"] as? [String: Any]
        let config = app["config"] as? [String: Any]
        let depotsNode = app["depots"] as? [String: Any] ?? [:]
        var depots: [SteamDepot] = []
        for (key, value) in depotsNode {
            guard let id = Int(key), let node = value as? [String: Any] else { continue }
            var depot = SteamDepot(id: id, name: (node["name"] as? String) ?? "")
            let depotConfig = node["config"] as? [String: Any]
            depot.osList = ((depotConfig?["oslist"] as? String) ?? "").lowercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            depot.osArch = (depotConfig?["osarch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            depot.language = (depotConfig?["language"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
            let manifests = node["manifests"] as? [String: Any]
            for (branch, entry) in manifests ?? [:] {
                if let gid = (entry as? String).flatMap({ UInt64($0) }) { depot.branchManifests[branch] = SteamDepotManifestEntry(gid: gid) }
                else if let dict = entry as? [String: Any], let gid = (dict["gid"] as? String).flatMap({ UInt64($0) }) {
                    depot.branchManifests[branch] = SteamDepotManifestEntry(gid: gid, size: (dict["size"] as? String).flatMap { UInt64($0) },
                                                                            download: (dict["download"] as? String).flatMap { UInt64($0) })
                }
            }
            if let entry = depot.branchManifests[SteamBranch.publicName] { depot.manifest = entry.gid; depot.size = entry.size; depot.download = entry.download }
            for (branch, entry) in (node["encryptedmanifests"] as? [String: Any]) ?? [:] {
                if let dict = entry as? [String: Any], let hex = dict["gid"] as? String, let bytes = Self.bytes(fromHex: hex), !bytes.isEmpty {
                    depot.encryptedManifests[branch] = SteamEncryptedManifest(gid: bytes, size: (dict["size"] as? String).flatMap { UInt64($0) },
                                                                              download: (dict["download"] as? String).flatMap { UInt64($0) })
                }
            }
            depot.fromApp = (node["depotfromapp"] as? String).flatMap { Int($0) }
            depot.dlcApp = (node["dlcappid"] as? String).flatMap { Int($0) }
            depot.optionalDLC = (node["optionaldlc"] as? String) == "1"
            depots.append(depot)
        }
        depots.sort { $0.id < $1.id }
        let branches = depotsNode["branches"] as? [String: Any]
        let buildID = ((branches?["public"] as? [String: Any])?["buildid"]) as? String
        var branchList: [SteamBranch] = []
        for (name, value) in branches ?? [:] {
            guard let node = value as? [String: Any] else { continue }
            branchList.append(SteamBranch(name: name, buildID: node["buildid"] as? String, description: (node["description"] as? String) ?? "",
                                          passwordRequired: (node["pwdrequired"] as? String) == "1",
                                          updated: (node["timeupdated"] as? String).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }))
        }
        branchList.sort { ($0.name == SteamBranch.publicName ? "" : "x" + $0.name) < ($1.name == SteamBranch.publicName ? "" : "x" + $1.name) }
        let dlcApps = Array(Set(depots.compactMap(\.dlcApp))).sorted()
        let listed = (((app["extended"] as? [String: Any])?["listofdlc"] as? String) ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        var launches: [SteamLaunchOption] = []
        if let launch = config?["launch"] as? [String: Any] {
            for key in launch.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
                guard let node = launch[key] as? [String: Any], let executable = node["executable"] as? String, !executable.isEmpty else { continue }
                let launchConfig = node["config"] as? [String: Any]
                launches.append(SteamLaunchOption(executable: executable, arguments: (node["arguments"] as? String) ?? "", type: (node["type"] as? String) ?? "",
                                                  oslist: ((launchConfig?["oslist"] as? String) ?? "").lowercased(), description: (node["description"] as? String) ?? "",
                                                  key: Int(key), osarch: (launchConfig?["osarch"] as? String) ?? ""))
            }
        }
        return SteamAppInfo(appid: appid, name: (common?["name"] as? String) ?? "App \(appid)", installDirectory: config?["installdir"] as? String,
                            buildID: buildID, depots: depots, type: ((common?["type"] as? String) ?? "").lowercased(), launches: launches,
                            branches: branchList, dlcApps: dlcApps, listedDLC: listed,
                            workshopDepot: (depotsNode["workshopdepot"] as? String).flatMap { Int($0) })
    }

    static func bytes(fromHex text: String) -> Data? {
        let hex = Array(text.utf8)
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        func nibble(_ c: UInt8) -> UInt8? { switch c { case 48...57: return c - 48; case 97...102: return c - 87; case 65...70: return c - 55; default: return nil } }
        var i = 0
        while i < hex.count {
            guard let hi = nibble(hex[i]), let lo = nibble(hex[i + 1]) else { return nil }
            out.append(hi << 4 | lo); i += 2
        }
        return out
    }
}

/// One depot to download and what it needs.
struct SteamDepotJob: Equatable {
    var depot: SteamDepot
    var manifest: UInt64
    /// The app whose ownership grants the key (the app itself, or the one this depot is shared from).
    var keyApp: Int
}

/// What to install of an app: which version (branch) and which DLC. The default is what Porthole always did: the public branch, the game's own files.
struct SteamInstallSelection: Equatable {
    enum DLC: Equatable { case none, all, only(Set<Int>), allExcept(Set<Int>) }
    var branch = SteamBranch.publicName
    /// The key of a password-protected branch (from Steam's answer to the password), needed to read that branch's encrypted manifest ids.
    var branchKey: Data?
    /// Which DLC depots to include. `.all` asks for every DLC depot; the ones the account does not own are skipped when their keys are refused.
    var dlc = DLC.none
    /// Repair: fetch the file lists of every depot even when the install record says it is current, and check the files on the disk against them.
    var verify = false

    func includes(dlcApp: Int) -> Bool {
        switch dlc { case .none: return false; case .all: return true; case .only(let set): return set.contains(dlcApp); case .allExcept(let set): return !set.contains(dlcApp) }
    }
}

enum SteamBetaCrypto {
    /// A password branch writes each manifest id encrypted with the branch's key (AES-256, ECB, one block); the id is the first eight bytes, little endian.
    static func decryptManifestID(_ encrypted: Data, key: Data) -> UInt64? {
        guard key.count == 32, encrypted.count >= 16, encrypted.count % 16 == 0, let plain = SteamCipher.decryptECB(encrypted, key: key), plain.count >= 8 else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(plain[plain.startIndex + i]) << (8 * UInt64(i)) }
        return value
    }
}

enum SteamDepotPlanner {
    /// The manifest id of a depot on a branch: the branch's own entry, else the encrypted one when the branch's key is known. nil when the depot is not part of that branch.
    static func manifestEntry(of depot: SteamDepot, selection: SteamInstallSelection) -> SteamDepotManifestEntry? {
        if let entry = depot.branchManifests[selection.branch] { return entry }
        if selection.branch == SteamBranch.publicName { return publicEntry(of: depot) }
        if selection.branch != SteamBranch.publicName, let encrypted = depot.encryptedManifests[selection.branch], let key = selection.branchKey,
           let gid = SteamBetaCrypto.decryptManifestID(encrypted.gid, key: key) {
            return SteamDepotManifestEntry(gid: gid, size: encrypted.size, download: encrypted.download)
        }
        return nil
    }

    /// The public branch's entry, from the depot's own fields when it was built without the branch table.
    static func publicEntry(of depot: SteamDepot) -> SteamDepotManifestEntry? {
        depot.branchManifests[SteamBranch.publicName] ?? depot.manifest.map { SteamDepotManifestEntry(gid: $0, size: depot.size, download: depot.download) }
    }

    /// The Windows depots of an app on a branch: English, 64-bit when there is a choice, the game's own plus the DLC the selection asks for. Each comes back with the
    /// manifest, size and download size of THAT branch. Depots shared from another app need that app's manifests (looked up on the same branch).
    static func windowsDepots(app: SteamAppInfo, selection: SteamInstallSelection = SteamInstallSelection()) -> [SteamDepot] {
        var chosen: [SteamDepot] = []
        for var depot in app.depots {
            if let dlc = depot.dlcApp, !selection.includes(dlcApp: dlc) { continue }
            guard depot.osList.isEmpty || depot.osList.contains("windows") else { continue }
            guard depot.language == nil || depot.language == "english" else { continue }
            if let entry = manifestEntry(of: depot, selection: selection) { depot.manifest = entry.gid; depot.size = entry.size; depot.download = entry.download }
            else { depot.manifest = nil; depot.size = nil; depot.download = nil }
            guard depot.manifest != nil || depot.fromApp != nil else { continue }
            chosen.append(depot)
        }
        if chosen.contains(where: { $0.osArch == "64" }) { chosen.removeAll { $0.osArch == "32" } }
        return chosen
    }

    /// What installing the app's Windows depots takes to download, and on disk. Depots shared from another app have no size here and are left out.
    static func sizes(app: SteamAppInfo, selection: SteamInstallSelection = SteamInstallSelection()) -> (download: UInt64, disk: UInt64) {
        let depots = windowsDepots(app: app, selection: selection).filter { $0.manifest != nil && $0.fromApp == nil }
        return (depots.reduce(0) { $0 + ($1.download ?? $1.size ?? 0) }, depots.reduce(0) { $0 + ($1.size ?? 0) })
    }

    /// Whether this is something to show in a library of games to install on Windows.
    static func isInstallableGame(_ app: SteamAppInfo) -> Bool {
        guard app.type == "game" else { return false }
        return !windowsDepots(app: app).isEmpty
    }

    static func safeInstallDirectory(_ app: SteamAppInfo) -> String {
        var name = (app.installDirectory ?? app.name).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "..", with: "_")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return name.isEmpty || name.allSatisfy({ $0 == "_" }) ? "App\(app.appid)" : name
    }
}

// MARK: - Manifests

struct SteamManifestChunk: Equatable {
    var sha: Data
    var checksum: UInt32
    var offset: UInt64
    var originalSize: Int
    var compressedSize: Int
}

struct SteamManifestFile: Equatable {
    var path: String            // forward slashes, relative to the game folder
    var size: UInt64
    var flags: UInt32
    var chunks: [SteamManifestChunk]
    var isDirectory: Bool { flags & 64 != 0 }
    var isSymlink: Bool { flags & 512 != 0 }
}

struct SteamManifest: Equatable {
    var depotID: Int
    var manifestID: UInt64
    var totalOriginal: UInt64
    var totalCompressed: UInt64
    var files: [SteamManifestFile]

    enum Failure: Error, Equatable { case notAManifest, badFilenames }

    /// Reads a manifest as the content server sends it (a zip with one entry) and decrypts its filenames with the depot key.
    static func parse(zipped: Data, depotKey: Data) throws -> SteamManifest {
        guard let payload = Deflate.unzipFirstEntry(zipped) else { throw Failure.notAManifest }
        return try parse(sections: payload, depotKey: depotKey)
    }

    static func parse(sections data: Data, depotKey: Data) throws -> SteamManifest {
        let bytes = Array(data)
        var at = 0
        func u32() -> UInt32? {
            guard at + 4 <= bytes.count else { return nil }
            defer { at += 4 }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        var payload: PBFields?, metadata: PBFields?
        while let magic = u32() {
            if magic == 0x32C4_15AB { break }                                   // end of manifest
            guard let length = u32(), at + Int(length) <= bytes.count else { throw Failure.notAManifest }
            let section = Data(bytes[at..<at + Int(length)]); at += Int(length)
            switch magic {
            case 0x71F6_17D0: payload = PBFields(section)
            case 0x1F48_12BE: metadata = PBFields(section)
            default: break                                                        // the signature is not needed to unpack files
            }
        }
        guard let payload, let metadata else { throw Failure.notAManifest }
        let encrypted = metadata.bool(4) ?? false
        var files: [SteamManifestFile] = []
        for mapping in payload.messages(1) {
            guard var name = mapping.string(1) else { throw Failure.badFilenames }
            if encrypted {
                guard let raw = Data(base64Encoded: name, options: .ignoreUnknownCharacters), let plain = SteamCipher.decrypt(raw, key: depotKey) else { throw Failure.badFilenames }
                var trimmed = plain
                while trimmed.last == 0 { trimmed.removeLast() }
                guard let decoded = String(data: trimmed, encoding: .utf8) else { throw Failure.badFilenames }
                name = decoded
            }
            name = name.replacingOccurrences(of: "\\", with: "/")
            let parts = name.split(separator: "/", omittingEmptySubsequences: true)
            guard !parts.isEmpty, !name.hasPrefix("/"), !parts.contains(".."), !parts.contains("."), !name.contains("\0") else { throw Failure.badFilenames }
            let chunks = mapping.messages(6).map { chunk in
                SteamManifestChunk(sha: chunk.data(1) ?? Data(), checksum: UInt32(truncatingIfNeeded: chunk.uint(2) ?? 0), offset: chunk.uint(3) ?? 0,
                                   originalSize: Int(chunk.uint(4) ?? 0), compressedSize: Int(chunk.uint(5) ?? 0))
            }
            files.append(SteamManifestFile(path: parts.joined(separator: "/"), size: mapping.uint(2) ?? 0, flags: UInt32(truncatingIfNeeded: mapping.uint(3) ?? 0), chunks: chunks))
        }
        return SteamManifest(depotID: metadata.int(1) ?? 0, manifestID: metadata.uint(2) ?? 0, totalOriginal: metadata.uint(5) ?? 0,
                             totalCompressed: metadata.uint(6) ?? 0, files: files)
    }
}

// MARK: - Content servers

struct SteamCDNServer: Equatable {
    var host: String
    var https: Bool
    /// Steam's own ranking of the server: lower priority class and lower load are better.
    var priority = 0
    var load = 0
}

enum SteamCDN {
    static func parse(_ reply: [String: Any]) -> [SteamCDNServer] {
        let list = (reply["servers"] as? [[String: Any]]) ?? []
        let usable = list.enumerated().compactMap { index, entry -> (SteamCDNServer, Bool, Int)? in
            guard let host = (entry["vhost"] as? String) ?? (entry["host"] as? String), !host.isEmpty else { return nil }
            let support = (entry["https_support"] as? String) ?? "optional"
            guard support != "unavailable" else { return nil }
            // Steam's own caches need no extra token; other hosts (CDN partners) want a per-depot token this build does not fetch.
            let server = SteamCDNServer(host: host, https: true, priority: SteamJSON.int(entry["priority_class"]) ?? 0,
                                        load: SteamJSON.int(entry["weighted_load"]) ?? SteamJSON.int(entry["load"]) ?? 0)
            return (server, host.hasSuffix(".steamcontent.com"), index)
        }
        func ranked(_ items: [(SteamCDNServer, Bool, Int)]) -> [SteamCDNServer] {
            items.sorted { ($0.0.priority, $0.0.load, $0.2) < ($1.0.priority, $1.0.load, $1.2) }.map { $0.0 }       // the directory's own order breaks ties
        }
        let ours = usable.filter { $0.1 }
        return ranked(ours.isEmpty ? usable : ours)
    }

    static func manifestURL(_ server: SteamCDNServer, depot: Int, manifest: UInt64, code: UInt64) -> URL? {
        URL(string: "https://\(server.host)/depot/\(depot)/manifest/\(manifest)/5/\(code)")
    }
    static func chunkURL(_ server: SteamCDNServer, depot: Int, sha: Data) -> URL? {
        URL(string: "https://\(server.host)/depot/\(depot)/chunk/\(sha.map { String(format: "%02x", $0) }.joined())")
    }
}

// MARK: - The seam

protocol SteamContentBackend: AnyObject {
    func appInfo(_ appid: Int, completion: @escaping (Result<SteamAppInfo, SteamContentError>) -> Void)
    func depotKey(app: Int, depot: Int, completion: @escaping (Result<Data, SteamContentError>) -> Void)
    func manifestCode(app: Int, depot: Int, manifest: UInt64, completion: @escaping (Result<UInt64, SteamContentError>) -> Void)
    func servers(completion: @escaping ([SteamCDNServer]) -> Void)
    func fetch(_ url: URL, completion: @escaping (Result<Data, SteamContentError>) -> Void)
    /// Asks Steam whether a password opens a beta of the app; the answer names the branch(es) it opens and gives each one's key.
    func checkBetaPassword(app: Int, password: String, completion: @escaping (Result<[SteamBetaPassword], SteamContentError>) -> Void)
    /// The account's achievements and stats for an app (Steam's "get user stats"): the schema and the unlock times.
    func userStats(app: Int, steamID: UInt64, completion: @escaping (Result<SteamUserStatsReply, SteamContentError>) -> Void)
    /// The Workshop items the account is subscribed to for an app, with the manifest of each item's files.
    func subscribedWorkshop(app: Int, completion: @escaping (Result<[SteamSubscribedFile], SteamContentError>) -> Void)
    func close()
}

extension SteamContentBackend {
    func subscribedWorkshop(app: Int, completion: @escaping (Result<[SteamSubscribedFile], SteamContentError>) -> Void) {
        completion(.failure(SteamContentError(message: "This connection cannot list subscribed Workshop items.")))
    }
    func userStats(app: Int, steamID: UInt64, completion: @escaping (Result<SteamUserStatsReply, SteamContentError>) -> Void) {
        completion(.failure(SteamContentError(message: "This connection cannot read achievements.")))
    }
    func checkBetaPassword(app: Int, password: String, completion: @escaping (Result<[SteamBetaPassword], SteamContentError>) -> Void) {
        completion(.failure(SteamContentError(message: "This connection cannot check beta passwords.")))
    }
}

/// What Steam answers to a beta password: the branch it opens, and the key that reads that branch's encrypted manifest ids.
struct SteamBetaPassword: Equatable {
    var branch: String
    var key: Data
    var description = ""
}

/// The real thing: Steam's connection managers for the questions, its content servers for the files.
final class SteamCMBackend: SteamContentBackend {
    let cm: SteamCM
    private let logOn: SteamLogOn
    private var ready = false
    private var starting = false
    private var pendingStart: [(Result<Void, SteamContentError>) -> Void] = []
    private let session: URLSession

    init(logOn: SteamLogOn, cm: SteamCM = SteamCM()) {
        self.logOn = logOn; self.cm = cm
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 48
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Connect and log on once; later calls reuse the connection.
    func start(_ completion: @escaping (Result<Void, SteamContentError>) -> Void) {
        if ready, cm.isLoggedOn { completion(.success(())); return }
        pendingStart.append(completion)
        guard !starting else { return }
        starting = true
        func finish(_ result: Result<Void, SteamContentError>) {
            starting = false; ready = { if case .success = result { return true } else { return false } }()
            let waiting = pendingStart; pendingStart = []
            for done in waiting { done(result) }
        }
        cm.onClose = { [weak self] _ in self?.ready = false }
        cm.connect { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): finish(.failure(SteamContentError(message: error.description)))
            case .success:
                self.cm.logOn(self.logOn) { logon in
                    switch logon {
                    case .success: SteamLog.event("Steam: connected to Steam's servers."); finish(.success(()))
                    case .failure(let error):
                        if case .logOnRefused(let code) = error { SteamLog.event("Steam: the sign-in for downloads was refused (result \(code)).") }
                        finish(.failure(SteamContentError(message: error.description, notOwned: false)))
                    }
                }
            }
        }
    }

    func close() { cm.disconnect(); ready = false }

    func appInfo(_ appid: Int, completion: @escaping (Result<SteamAppInfo, SteamContentError>) -> Void) {
        start { [weak self] started in
            guard let self else { return }
            if case .failure(let error) = started { completion(.failure(error)); return }
            var tokenRequest = PBWriter(); tokenRequest.varint(2, UInt64(appid))
            self.cm.wait(for: EMsg.picsAccessTokenResponse, timeout: 20, match: { _ in true }) { reply in
                var token: UInt64 = 0
                if case .success(let packet) = reply, let fields = PBFields(packet.body) {
                    token = fields.messages(3).first { $0.uint(1) == UInt64(appid) }?.uint(2) ?? 0
                }
                self.requestProductInfo(appid: appid, token: token, completion: completion)
            }
            self.cm.send(EMsg.picsAccessTokenRequest, body: tokenRequest.data)
        }
    }

    private func requestProductInfo(appid: Int, token: UInt64, completion: @escaping (Result<SteamAppInfo, SteamContentError>) -> Void) {
        var app = PBWriter(); app.varint(1, UInt64(appid)); if token != 0 { app.varint(2, token) }
        var request = PBWriter(); request.message(2, app); request.bool(3, false)
        var buffer: Data?
        func waitForNext() {
            cm.wait(for: EMsg.picsProductInfoResponse, timeout: 30, match: { _ in true }) { reply in
                switch reply {
                case .failure(let error): completion(.failure(SteamContentError(message: error.description)))
                case .success(let packet):
                    let fields = PBFields(packet.body)
                    if let entry = fields?.messages(1).first(where: { $0.uint(1) == UInt64(appid) }) {
                        if let data = entry.data(5), !data.isEmpty { buffer = data }
                    }
                    if fields?.bool(6) == true { waitForNext(); return }
                    guard let buffer, let info = SteamAppInfoParser.parse(buffer, appid: appid) else {
                        completion(.failure(SteamContentError(message: "Steam gave no information for app \(appid) (the account may not own it).", notOwned: true))); return
                    }
                    completion(.success(info))
                }
            }
        }
        waitForNext()
        cm.send(EMsg.picsProductInfoRequest, body: request.data)
    }

    func depotKey(app: Int, depot: Int, completion: @escaping (Result<Data, SteamContentError>) -> Void) {
        start { [weak self] started in
            guard let self else { return }
            if case .failure(let error) = started { completion(.failure(error)); return }
            var request = PBWriter(); request.varint(1, UInt64(depot)); request.varint(2, UInt64(app))
            self.cm.wait(for: EMsg.getDepotDecryptionKeyResponse, timeout: 20, match: { PBFields($0.body)?.uint(2) == UInt64(depot) }) { reply in
                switch reply {
                case .failure(let error): completion(.failure(SteamContentError(message: error.description)))
                case .success(let packet):
                    let fields = PBFields(packet.body)
                    let code = fields?.int(1) ?? 2
                    if code == 1, let key = fields?.data(3), key.count == 32 { completion(.success(key)) }
                    else { completion(.failure(SteamContentError(message: code == 15 ? "This account does not own depot \(depot)." : "Steam would not give the key for depot \(depot) (error \(code)).", notOwned: code == 15))) }
                }
            }
            self.cm.send(EMsg.getDepotDecryptionKey, body: request.data)
        }
    }

    func checkBetaPassword(app: Int, password: String, completion: @escaping (Result<[SteamBetaPassword], SteamContentError>) -> Void) {
        start { [weak self] started in
            guard let self else { return }
            if case .failure(let error) = started { completion(.failure(error)); return }
            var request = PBWriter(); request.varint(1, UInt64(app)); request.string(2, password)
            self.cm.wait(for: EMsg.checkAppBetaPasswordResponse, timeout: 20, match: { _ in true }) { reply in
                switch reply {
                case .failure(let error): completion(.failure(SteamContentError(message: error.description)))
                case .success(let packet):
                    let fields = PBFields(packet.body)
                    let code = fields?.int(1) ?? 2
                    guard code == 1 else {
                        completion(.failure(SteamContentError(message: code == 5 ? "Steam does not accept that password." : "Steam could not check the password (error \(code)).")))
                        return
                    }
                    let found = (fields?.messages(4) ?? []).compactMap { entry -> SteamBetaPassword? in
                        guard let name = entry.string(1), !name.isEmpty, let hex = entry.string(2), let key = SteamAppInfoParser.bytes(fromHex: hex), key.count == 32 else { return nil }
                        return SteamBetaPassword(branch: name, key: key, description: entry.string(3) ?? "")
                    }
                    if found.isEmpty { completion(.failure(SteamContentError(message: "That password does not open a beta of this game."))) } else { completion(.success(found)) }
                }
            }
            self.cm.send(EMsg.checkAppBetaPassword, body: request.data)
        }
    }

    func userStats(app: Int, steamID: UInt64, completion: @escaping (Result<SteamUserStatsReply, SteamContentError>) -> Void) {
        start { [weak self] started in
            guard let self else { return }
            if case .failure(let error) = started { completion(.failure(error)); return }
            // game id; crc 0 and schema version -1 ask for the whole schema; the account whose stats are wanted.
            var request = PBWriter()
            request.fixed64(1, UInt64(app)); request.varint(2, 0); request.int32(3, -1); request.fixed64(4, steamID)
            self.cm.wait(for: EMsg.getUserStatsResponse, timeout: 25, match: { PBFields($0.body)?.uint(1) == UInt64(app) }) { reply in
                switch reply {
                case .failure(let error): completion(.failure(SteamContentError(message: error.description)))
                case .success(let packet): completion(SteamAchievementParser.reply(from: packet.body))
                }
            }
            self.cm.send(EMsg.getUserStats, body: request.data)
        }
    }

    func subscribedWorkshop(app: Int, completion: @escaping (Result<[SteamSubscribedFile], SteamContentError>) -> Void) {
        start { [weak self] started in
            guard let self else { return }
            if case .failure(let error) = started { completion(.failure(error)); return }
            var found: [SteamSubscribedFile] = []
            func page(_ start: Int) {
                var request = PBWriter(); request.varint(1, UInt64(app)); request.varint(2, UInt64(start))
                self.cm.wait(for: EMsg.enumerateSubscribedFilesResponse, timeout: 25, match: { _ in true }) { reply in
                    switch reply {
                    case .failure(let error): completion(.failure(SteamContentError(message: error.description)))
                    case .success(let packet):
                        switch SteamWorkshopParser.subscribed(from: packet.body) {
                        case .failure(let error): completion(.failure(error))
                        case .success(let answer):
                            found += answer.files
                            if answer.files.isEmpty || found.count >= answer.total || found.count > 5000 { completion(.success(found)) } else { page(found.count) }
                        }
                    }
                }
                self.cm.send(EMsg.enumerateSubscribedFiles, body: request.data)
            }
            page(0)
        }
    }

    func manifestCode(app: Int, depot: Int, manifest: UInt64, completion: @escaping (Result<UInt64, SteamContentError>) -> Void) {
        start { [weak self] started in
            guard let self else { return }
            if case .failure(let error) = started { completion(.failure(error)); return }
            var request = PBWriter(); request.varint(1, UInt64(app)); request.varint(2, UInt64(depot)); request.varint(3, manifest)
            self.cm.call("ContentServerDirectory.GetManifestRequestCode#1", body: request.data) { reply in
                switch reply {
                case .failure(let error): completion(.failure(SteamContentError(message: error.description)))
                case .success(let body): completion(.success(PBFields(body)?.uint(1) ?? 0))
                }
            }
        }
    }

    func servers(completion: @escaping ([SteamCDNServer]) -> Void) {
        let cell = cm.cellID
        var request = URLRequest(url: URL(string: "\(SteamAPI.host)/IContentServerDirectoryService/GetServersForSteamPipe/v1/?cell_id=\(cell)&max_servers=24&format=json")!)
        request.timeoutInterval = 20
        session.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            DispatchQueue.main.async { completion(SteamCDN.parse((json?["response"] as? [String: Any]) ?? [:])) }
        }.resume()
    }

    func fetch(_ url: URL, completion: @escaping (Result<Data, SteamContentError>) -> Void) {
        session.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, status == 200 { completion(.success(data)) }
            else { completion(.failure(SteamContentError(message: error?.localizedDescription ?? "HTTP \(status)", notOwned: status == 401 || status == 403))) }
        }.resume()
    }
}
