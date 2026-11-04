// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// GOG's "generation 2" content system, the one GOG Galaxy uses: a build's meta manifest lists depots; a depot's manifest lists files as MD5-addressed,
// zlib-compressed chunks on GOG's CDN (with a "small files container" that packs many tiny files into shared chunks). The public parts (build list,
// manifests) need no login; the chunks need a short-lived secure link from the signed-in account. This file reads the manifests and fetches verified
// chunks; the install itself is in GogInstaller.swift. Format knowledge comes from the open-source GOG clients (heroic-gogdl, lgogdownloader).

import Foundation
import CryptoKit
import zlib

enum GogContentError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

// MARK: - Manifests

struct GogChunk: Equatable {
    let md5: String
    let compressedMd5: String
    let size: Int
    let compressedSize: Int
}

struct GogDepotItem {
    /// Always with forward slashes, never absolute or containing "..".
    let path: String
    let isDirectory: Bool
    let chunks: [GogChunk]
    let md5: String?
    let sha256: String?
    let flags: [String]
    /// A file packed into the depot's small-files container: where, and how long.
    let container: (offset: Int, size: Int)?
    var size: Int { container?.size ?? chunks.reduce(0) { $0 + $1.size } }
    var isSupport: Bool { flags.contains("support") }
    func moved(to path: String) -> GogDepotItem {
        GogDepotItem(path: path, isDirectory: isDirectory, chunks: chunks, md5: md5, sha256: sha256, flags: flags, container: container)
    }
}

struct GogDepotManifest {
    let items: [GogDepotItem]
    let containerChunks: [GogChunk]
}

struct GogMetaDepot {
    let manifest: String
    let productId: String
    let languages: [String]
    let isGogDepot: Bool
    let size: UInt64
    let compressedSize: UInt64
}

struct GogBuildMeta {
    let buildID: String
    let baseProductId: String
    let installDirectory: String
    let depots: [GogMetaDepot]
    let dependencies: [String]
    /// The game's own Galaxy client identity (clientId and clientSecret in the build's manifest), for the Galaxy service; nil when the build has none.
    let galaxy: GOGGalaxyClient?
}

enum GogContent {
    static let metaHost = "https://cdn.gog.com/content-system/v2/meta"

    /// The newest generation-2 Windows build of a product, or nil when GOG has none (older games are installer-only, or generation 1).
    static func latestBuild(productID: Int) async throws -> (id: String, link: URL)? {
        var components = URLComponents(string: "https://content-system.gog.com/products/\(productID)/os/windows/builds")!
        components.queryItems = [URLQueryItem(name: "generation", value: "2")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let (data, response) = try await StoreNetwork.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let items = json["items"] as? [[String: Any]] else {
            throw GogContentError.invalid("GOG's build list could not be read.")
        }
        // Newest first: the first public, main-branch (no beta branch), generation-2 build.
        for item in items {
            guard (item["generation"] as? Int) == 2 else { continue }
            if let isPublic = item["public"] as? Bool, !isPublic { continue }
            if let branch = item["branch"] as? String, !branch.isEmpty { continue }
            if let id = item["build_id"] as? String, let link = (item["link"] as? String).flatMap(URL.init(string:)), link.scheme == "https" { return (id, link) }
        }
        return nil
    }

    private static func fetchJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await StoreNetwork.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GogContentError.invalid("GOG's manifest answered \(status).") }
        // The manifests are zlib-compressed JSON; a plain one is accepted too.
        let plain = (try? GogZlib.inflate(data, limit: 256 * 1024 * 1024)) ?? data
        guard let json = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw GogContentError.invalid("GOG's manifest was not understood.") }
        return json
    }

    static func meta(link: URL, buildID: String) async throws -> GogBuildMeta {
        guard link.host?.hasSuffix("gog.com") == true else { throw GogContentError.invalid("GOG's build link points somewhere unexpected.") }
        let json = try await fetchJSON(link)
        let depots = (json["depots"] as? [[String: Any]] ?? []).compactMap { d -> GogMetaDepot? in
            guard let manifest = d["manifest"] as? String, manifest.count == 32, manifest.allSatisfy(\.isHexDigit) else { return nil }
            return GogMetaDepot(manifest: manifest.lowercased(), productId: "\(d["productId"] ?? "")", languages: (d["languages"] as? [String]) ?? [],
                                isGogDepot: (d["isGogDepot"] as? Bool) ?? false,
                                size: (d["size"] as? NSNumber)?.uint64Value ?? 0, compressedSize: (d["compressedSize"] as? NSNumber)?.uint64Value ?? 0)
        }
        return GogBuildMeta(buildID: buildID, baseProductId: "\(json["baseProductId"] ?? "")", installDirectory: (json["installDirectory"] as? String) ?? "",
                            depots: depots, dependencies: (json["dependencies"] as? [String]) ?? [],
                            galaxy: GOGGalaxyClient(id: Self.idString(json["clientId"]), secret: json["clientSecret"] as? String))
    }

    /// GOG writes a client id as a string or as a number.
    private static func idString(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func depot(_ md5: String) async throws -> GogDepotManifest {
        guard let url = URL(string: "\(metaHost)/\(md5.prefix(2))/\(md5.dropFirst(2).prefix(2))/\(md5)") else { throw GogContentError.invalid("Bad depot address.") }
        let json = try await fetchJSON(url)
        let depot = (json["depot"] as? [String: Any]) ?? json
        var items: [GogDepotItem] = []
        for raw in depot["items"] as? [[String: Any]] ?? [] {
            guard let type = raw["type"] as? String, let path = safePath(raw["path"] as? String) else {
                if raw["path"] != nil, safePath(raw["path"] as? String) == nil { throw GogContentError.invalid("GOG's file list holds an unsafe path.") }
                continue
            }
            if type == "DepotDirectory" {
                items.append(GogDepotItem(path: path, isDirectory: true, chunks: [], md5: nil, sha256: nil, flags: [], container: nil)); continue
            }
            guard type == "DepotFile" else { continue }              // links and anything newer are not used by Windows games
            let chunks = (raw["chunks"] as? [[String: Any]] ?? []).compactMap(chunk)
            var container: (Int, Int)?
            if let ref = raw["sfcRef"] as? [String: Any], let offset = (ref["offset"] as? NSNumber)?.intValue, let size = (ref["size"] as? NSNumber)?.intValue {
                container = (offset, size)
            }
            items.append(GogDepotItem(path: path, isDirectory: false, chunks: chunks, md5: (raw["md5"] as? String)?.lowercased(),
                                      sha256: (raw["sha256"] as? String)?.lowercased(), flags: (raw["flags"] as? [String]) ?? [], container: container))
        }
        let container = ((depot["smallFilesContainer"] as? [String: Any])?["chunks"] as? [[String: Any]] ?? []).compactMap(chunk)
        return GogDepotManifest(items: items, containerChunks: container)
    }

    private static func chunk(_ raw: [String: Any]) -> GogChunk? {
        guard let md5 = raw["md5"] as? String, let compressed = raw["compressedMd5"] as? String, md5.count == 32, compressed.count == 32,
              let size = (raw["size"] as? NSNumber)?.intValue, let compressedSize = (raw["compressedSize"] as? NSNumber)?.intValue,
              size > 0, size <= 256 * 1024 * 1024, compressedSize > 0 else { return nil }
        return GogChunk(md5: md5.lowercased(), compressedMd5: compressed.lowercased(), size: size, compressedSize: compressedSize)
    }

    /// A depot path as a relative path with forward slashes, or nil when it could point outside the game folder.
    static func safePath(_ raw: String?) -> String? {
        guard var path = raw?.replacingOccurrences(of: "\\", with: "/"), !path.isEmpty else { return nil }
        while path.hasSuffix("/") { path.removeLast() }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains(":") || $0.contains("\0") }) else { return nil }
        return path
    }

    /// Which depots a main-product install takes: the base product's own, those for every language ("*") and for one chosen language, plus GOG's own small
    /// depots for that language (they hold goggame-<id>.info). Redistributables and other products' depots (add-ons) are left out.
    static func chooseDepots(_ meta: GogBuildMeta, preferred: String) -> [GogMetaDepot] {
        let mine = meta.depots.filter { $0.productId == meta.baseProductId || meta.baseProductId.isEmpty }
        var languages = Set<String>()
        for d in mine { for l in d.languages where l != "*" { languages.insert(l) } }
        let wanted = preferred.lowercased()
        let chosen = languages.first { $0.lowercased() == wanted }
            ?? languages.first { $0.lowercased().hasPrefix(String(wanted.prefix(2))) }
            ?? languages.first { $0.lowercased() == "en-us" }
            ?? languages.sorted().first
        return mine.filter { d in d.languages.isEmpty || d.languages.contains("*") || (chosen.map { d.languages.contains($0) } ?? false) }
    }
}

// MARK: - Chunks

/// Fetches chunks from GOG's CDN with a secure link for the product, renewing it when it stops working, and returns the verified, decompressed bytes.
actor GogChunkSource {
    private struct Endpoint { let name: String; let format: String; let params: [String: String]; let priority: Int }
    private let productId: String
    private var endpoints: [Endpoint] = []
    private let session: URLSession

    init(productId: String) {
        self.productId = productId
        let configuration = StoreNetwork.configuration()
        configuration.httpMaximumConnectionsPerHost = 32   // the look-ahead window keeps up to 48 chunks in flight (ChunkWindow)
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    private func refresh() async throws {
        let token = try await GogAuth.shared.validAccessToken()
        var components = URLComponents(string: "https://content-system.gog.com/products/\(productId)/secure_link")!
        components.queryItems = [URLQueryItem(name: "_version", value: "2"), URLQueryItem(name: "generation", value: "2"), URLQueryItem(name: "path", value: "/")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let urls = json["urls"] as? [[String: Any]] else {
            LogStore.shared.log("[gog-install] secure link answered \(status), \(data.count) bytes", level: .error)
            throw GogContentError.invalid("GOG did not give a download link for this game (answer \(status)).")
        }
        endpoints = urls.compactMap { u in
            guard let format = u["url_format"] as? String, let raw = u["parameters"] as? [String: Any] else { return nil }
            var params: [String: String] = [:]
            for (k, v) in raw { params[k] = "\(v)" }
            return Endpoint(name: (u["endpoint_name"] as? String) ?? "?", format: format, params: params, priority: (u["priority"] as? Int) ?? 99)
        }.sorted { $0.priority < $1.priority }
        LogStore.shared.log("[gog-install] secure link: \(endpoints.count) endpoint(s): \(endpoints.map(\.name).joined(separator: ", "))")
        guard !endpoints.isEmpty else { throw GogContentError.invalid("GOG's download link had no servers in it.") }
    }

    private func url(_ endpoint: Endpoint, _ compressedMd5: String) -> URL? {
        var params = endpoint.params
        params["path"] = (params["path"] ?? "") + "/\(compressedMd5.prefix(2))/\(compressedMd5.dropFirst(2).prefix(2))/\(compressedMd5)"
        var text = endpoint.format
        for (k, v) in params { text = text.replacingOccurrences(of: "{\(k)}", with: v) }
        // "{base_url}/{path}" with a path that starts with "/" doubles a slash; the part before any "?" is tidied (never the scheme).
        if let scheme = text.range(of: "://") {
            var rest = String(text[scheme.upperBound...])
            var query = ""
            if let q = rest.firstIndex(of: "?") { query = String(rest[q...]); rest = String(rest[..<q]) }
            while rest.contains("//") { rest = rest.replacingOccurrences(of: "//", with: "/") }
            text = String(text[..<scheme.upperBound]) + rest + query
        }
        guard let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }

    /// The compressed bytes of a chunk, from the best server that answers.
    func raw(_ compressedMd5: String) async throws -> Data {
        if endpoints.isEmpty { try await refresh() }
        var lastStatus = 0
        for attempt in 0..<2 {
            for endpoint in endpoints {
                guard let url = url(endpoint, compressedMd5) else { continue }
                do {
                    let (data, response) = try await session.data(from: url)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 200 { return data }
                    lastStatus = status
                } catch {
                    if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
                    lastStatus = (error as NSError).code
                }
            }
            // Every server refused: the link may have expired. Renew it once.
            if attempt == 0 { try await refresh() }
        }
        LogStore.shared.log("[gog-install] chunk fetch failed on every server (last status \(lastStatus))", level: .error)
        throw GogContentError.invalid("GOG's servers refused the download (\(lastStatus)). Try again.")
    }

    /// Checks a downloaded chunk against the manifest and returns its decompressed bytes.
    nonisolated static func decode(_ raw: Data, as chunk: GogChunk) throws -> Data {
        guard md5(raw) == chunk.compressedMd5 else { throw GogContentError.invalid("A downloaded piece failed GOG's checksum. Try again.") }
        let data = try GogZlib.inflate(raw, expectedSize: chunk.size)
        guard data.count == chunk.size, md5(data) == chunk.md5 else { throw GogContentError.invalid("A downloaded piece did not match GOG's manifest. Try again.") }
        return data
    }

    nonisolated static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - zlib

enum GogZlib {
    /// Decompresses a zlib stream whose size is not known in advance (manifests).
    static func inflate(_ input: Data, limit: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw GogContentError.invalid("zlib could not start.") }
        defer { inflateEnd(&stream) }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var status: Int32 = Z_OK
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            repeat {
                let produced: Int = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return out.count - Int(stream.avail_out)
                }
                output.append(contentsOf: buffer[0..<produced])
                if output.count > limit { throw GogContentError.invalid("GOG's manifest is larger than expected.") }
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw GogContentError.invalid("A GOG manifest was not valid zlib data.") }
        return output
    }

    /// Decompresses a chunk whose uncompressed size the manifest states.
    static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        var output = Data(count: expectedSize)
        var length = uLongf(expectedSize)
        let status = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                uncompress(dst.bindMemory(to: Bytef.self).baseAddress, &length, src.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
            }
        }
        guard status == Z_OK, Int(length) == expectedSize else { throw GogContentError.invalid("A downloaded piece was not valid zlib data.") }
        return output
    }
}
