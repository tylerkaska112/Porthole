// SPDX-License-Identifier: GPL-3.0-or-later
// Test support (used by the Mac tests and the simulator host): a stand-in for Steam's content servers that builds manifests and
// chunks in the real formats (protobuf sections in a zip, encrypted filenames, encrypted chunks), so the installer runs its
// whole path against it.
import Foundation

enum ContentFixture {
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 { var c = UInt32(i); for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; table[i] = c }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }

    /// A zip file with one stored (uncompressed) entry.
    static func zipStored(name: String, data: Data) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        let nameBytes = Array(name.utf8), crc = crc32(data)
        var out = Data()
        out.append(contentsOf: le32(0x04034B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(nameBytes.count) + le16(0))
        out.append(contentsOf: nameBytes); out.append(data)
        let centralAt = out.count
        out.append(contentsOf: le32(0x02014B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count))
                   + le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0))
        out.append(contentsOf: nameBytes)
        let centralSize = out.count - centralAt
        out.append(contentsOf: le32(0x06054B50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(UInt32(centralSize)) + le32(UInt32(centralAt)) + le16(0))
        return out
    }

    /// Deterministic bytes that look a bit like data.
    static func bytes(size: Int, seed: UInt32) -> Data {
        var x = seed == 0 ? 1 : seed
        var out = Data(capacity: size)
        while out.count < size { x ^= x << 13; x ^= x >> 17; x ^= x << 5; out.append(UInt8(truncatingIfNeeded: x >> 8)) }
        return out
    }

    struct File {
        var path: String
        var data: Data
        var flags: UInt32 = 0
        var isDirectory: Bool { flags & 64 != 0 }
    }

    struct Depot {
        var id: Int
        var manifestID: UInt64
        var key: Data
        var manifestZip: Data
        var chunks: [String: Data]          // encrypted chunk bytes by lowercase hex SHA-1
        var files: [File]
        var totalSize: UInt64 { files.reduce(0) { $0 + UInt64($1.data.count) } }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func makeDepot(id: Int, manifestID: UInt64, key: Data, files: [File], chunkSize: Int = 1000, encryptNames: Bool = true) -> Depot {
        var payload = PBWriter()
        var chunks: [String: Data] = [:]
        var uniqueBytes: UInt64 = 0, total: UInt64 = 0
        for file in files {
            var mapping = PBWriter()
            var name = Data(file.path.utf8)
            if encryptNames {
                name.append(0)
                let sealed = SteamCipher.encrypt(name, key: key, iv: Data((0..<16).map { UInt8(($0 &* 5 &+ file.path.utf8.count) & 0xFF) }))!
                // Real manifests wrap long base64 lines; the reader has to cope.
                let encoded = sealed.base64EncodedString()
                mapping.string(1, encoded.count > 40 ? String(encoded.prefix(40)) + "\n" + String(encoded.dropFirst(40)) + "\n" : encoded + "\n")
            } else { mapping.string(1, file.path) }
            mapping.varint(2, UInt64(file.data.count)); mapping.varint(3, UInt64(file.flags))
            mapping.bytes(4, SteamCipher.sha1(Data(file.path.utf8))); mapping.bytes(5, SteamCipher.sha1(file.data))
            var offset = 0
            while offset < file.data.count {
                let piece = file.data.subdata(in: offset..<min(offset + chunkSize, file.data.count))
                let sha = SteamCipher.sha1(piece)
                var chunk = PBWriter()
                chunk.bytes(1, sha); chunk.varint(2, UInt64(SteamCipher.adler32(piece))); chunk.varint(3, UInt64(offset))
                chunk.varint(4, UInt64(piece.count))
                let wrapped = zipStored(name: "z", data: piece)
                let sealed = SteamCipher.encrypt(wrapped, key: key, iv: Data((0..<16).map { UInt8(($0 &* 13 &+ offset) & 0xFF) }))!
                chunk.varint(5, UInt64(sealed.count))
                chunks[hex(sha)] = sealed
                mapping.message(6, chunk)
                offset += piece.count; uniqueBytes += UInt64(piece.count)
            }
            total += UInt64(file.data.count)
            payload.message(1, mapping)
        }
        var meta = PBWriter()
        meta.varint(1, UInt64(id)); meta.varint(2, manifestID); meta.varint(3, 1_700_000_000); meta.bool(4, encryptNames)
        meta.varint(5, total); meta.varint(6, uniqueBytes); meta.varint(7, UInt64(chunks.count))
        var sections = Data()
        func section(_ magic: UInt32, _ body: Data) {
            for v in [magic, UInt32(body.count)] { for i in 0..<4 { sections.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
            sections.append(body)
        }
        section(0x71F6_17D0, payload.data); section(0x1F48_12BE, meta.data); section(0x1B81_B817, Data())
        for i in 0..<4 { sections.append(UInt8((UInt32(0x32C4_15AB) >> (8 * UInt32(i))) & 0xFF)) }
        return Depot(id: id, manifestID: manifestID, key: key, manifestZip: zipStored(name: "z", data: sections), chunks: chunks, files: files)
    }

    /// App information as Steam's text KeyValues would carry it.
    /// Steam writes a quote or a backslash inside a text value with a backslash in front.
    static func escaped(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    static func appInfoText(appid: Int, name: String, installDir: String, depots: [(id: Int, manifest: UInt64, size: UInt64, extra: String)]) -> Data {
        var text = "\"appinfo\"\n{\n\t\"appid\"\t\"\(appid)\"\n\t\"common\"\n\t{\n\t\t\"name\"\t\"\(escaped(name))\"\n\t}\n\t\"config\"\n\t{\n\t\t\"installdir\"\t\"\(escaped(installDir))\"\n\t}\n\t\"depots\"\n\t{\n"
        for depot in depots {
            text += "\t\t\"\(depot.id)\"\n\t\t{\n\t\t\t\"manifests\"\n\t\t\t{\n\t\t\t\t\"public\"\n\t\t\t\t{\n\t\t\t\t\t\"gid\"\t\"\(depot.manifest)\"\n\t\t\t\t\t\"size\"\t\"\(depot.size)\"\n\t\t\t\t}\n\t\t\t}\n\(depot.extra)\t\t}\n"
        }
        text += "\t\t\"branches\"\n\t\t{\n\t\t\t\"public\"\n\t\t\t{\n\t\t\t\t\"buildid\"\t\"777\"\n\t\t\t}\n\t\t}\n\t}\n}\n"
        return Data(text.utf8) + Data([0])
    }
}

/// A Steam that serves what it was given.
final class FakeContent: SteamContentBackend {
    var apps: [Int: SteamAppInfo] = [:]
    var depots: [Int: ContentFixture.Depot] = [:]
    var notOwnedDepots: Set<Int> = []
    /// Depots whose key Steam answers with "blocked" (error 40).
    var blockedDepots: Set<Int> = []
    var appInfoFailure: SteamContentError?
    var noServers = false
    var delay: TimeInterval = 0
    /// Chunk hashes (hex) whose first N requests fail with a network error.
    var failFirstRequests: [String: Int] = [:]
    /// Chunk hashes whose first N answers are wrong bytes.
    var corruptFirstAnswers: [String: Int] = [:]
    var alwaysFail: Set<String> = []
    /// Called before each chunk is served, on a background queue.
    var onChunk: ((Int) -> Void)?
    private let lock = NSLock()
    private(set) var chunkRequests = 0
    private(set) var requested: [String] = []
    private(set) var isClosed = false
    private(set) var keyRequests: [Int] = []

    func appInfo(_ appid: Int, completion: @escaping (Result<SteamAppInfo, SteamContentError>) -> Void) {
        let result: Result<SteamAppInfo, SteamContentError>
        if let failure = appInfoFailure { result = .failure(failure) }
        else if let info = apps[appid] { result = .success(info) }
        else { result = .failure(SteamContentError(message: "Steam gave no information for app \(appid).", notOwned: true)) }
        DispatchQueue.main.async { completion(result) }
    }
    func depotKey(app: Int, depot: Int, completion: @escaping (Result<Data, SteamContentError>) -> Void) {
        lock.lock(); keyRequests.append(depot); lock.unlock()
        let result: Result<Data, SteamContentError>
        if notOwnedDepots.contains(depot) { result = .failure(SteamContentError(message: "This account does not own depot \(depot).", notOwned: true)) }
        else if blockedDepots.contains(depot) { result = .failure(.forDepotKey(code: 40, depot: depot)) }
        else if let d = depots[depot] { result = .success(d.key) }
        else { result = .failure(SteamContentError(message: "no such depot")) }
        DispatchQueue.main.async { completion(result) }
    }
    func manifestCode(app: Int, depot: Int, manifest: UInt64, completion: @escaping (Result<UInt64, SteamContentError>) -> Void) {
        DispatchQueue.main.async { completion(.success(424242)) }
    }
    func servers(completion: @escaping ([SteamCDNServer]) -> Void) {
        let list = noServers ? [] : [SteamCDNServer(host: "cdn-a.example", https: true), SteamCDNServer(host: "cdn-b.example", https: true)]
        DispatchQueue.main.async { completion(list) }
    }
    func fetch(_ url: URL, completion: @escaping (Result<Data, SteamContentError>) -> Void) {
        let parts = url.path.split(separator: "/").map(String.init)           // depot, <id>, manifest|chunk, ...
        guard parts.count >= 4, parts[0] == "depot", let id = Int(parts[1]), let depot = depots[id] else { completion(.failure(SteamContentError(message: "HTTP 404"))); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            if parts[2] == "manifest" {
                completion(parts[3] == String(depot.manifestID) ? .success(depot.manifestZip) : .failure(SteamContentError(message: "HTTP 404"))); return
            }
            let key = parts[3]
            lock.lock()
            chunkRequests += 1; requested.append(key)
            let count = chunkRequests
            let failing = alwaysFail.contains(key) || (failFirstRequests[key] ?? 0) > 0
            if !alwaysFail.contains(key), let left = failFirstRequests[key], left > 0 { failFirstRequests[key] = left - 1 }
            let corrupt = (corruptFirstAnswers[key] ?? 0) > 0
            if corrupt, let left = corruptFirstAnswers[key] { corruptFirstAnswers[key] = left - 1 }
            lock.unlock()
            onChunk?(count)
            if failing { completion(.failure(SteamContentError(message: "connection lost"))); return }
            guard var data = depot.chunks[key] else { completion(.failure(SteamContentError(message: "HTTP 404"))); return }
            if corrupt { data[data.count - 3] ^= 0x55 }
            completion(.success(data))
        }
    }
    func close() { lock.lock(); isClosed = true; lock.unlock() }
}
