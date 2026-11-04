// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Which of Steam's content servers the next chunk goes to. Servers differ a lot (how busy they are, whether they already hold the game), so each
/// request goes to the server that is doing best right now: fastest recent requests, and fewest requests already waiting on it. A server that
/// fails sits out for a while. A few servers are used at first, so their connections stay warm; more are added as the load grows.
final class SteamHostBook: @unchecked Sendable {
    struct Entry {
        var speed = 0.0                 // bytes per second of a typical recent request (smoothed)
        var inFlight = 0
        var requests = 0, failures = 0
        var bytes: UInt64 = 0
        var seconds = 0.0
        var sitOutUntil = Date.distantPast
    }

    private let lock = NSLock()
    private let hosts: [SteamCDNServer]
    private var entries: [String: Entry] = [:]
    private var active: Int
    private var chooses = 0

    /// `hosts` come best first (the directory's own order of priority and load).
    init(hosts: [SteamCDNServer], startWith: Int = 6) {
        self.hosts = Self.spreadOverSites(hosts)
        active = min(max(1, startWith), max(1, hosts.count))
    }

    /// The place a server is in, from its name: "cache8-dfw2.steamcontent.com" is in "dfw2". Servers of one site share a route to the device.
    static func site(of host: String) -> String {
        guard let dash = host.firstIndex(of: "-"), let dot = host[dash...].firstIndex(of: ".") else { return host }
        return String(host[host.index(after: dash)..<dot])
    }

    /// Takes the servers site by site in turn (the best server of each site, then the second best of each, ...), so the first few the downloader
    /// uses cover every site. Which site is fast depends on the device's network, so each gets a turn and the measured speed decides.
    /// Only sites of the best priority class are mixed in; the rest follow.
    static func spreadOverSites(_ hosts: [SteamCDNServer]) -> [SteamCDNServer] {
        guard let best = hosts.map(\.priority).min() else { return hosts }
        let near = hosts.filter { $0.priority == best }, far = hosts.filter { $0.priority != best }
        var sites: [String] = [], bySite: [String: [SteamCDNServer]] = [:]
        for host in near {
            let name = site(of: host.host)
            if bySite[name] == nil { sites.append(name) }
            bySite[name, default: []].append(host)
        }
        var ordered: [SteamCDNServer] = []
        var round = 0
        while ordered.count < near.count {
            for name in sites { if let list = bySite[name], round < list.count { ordered.append(list[round]) } }
            round += 1
        }
        return ordered + far
    }

    /// Picks a server for one request and counts it as waiting there.
    func choose(now: Date = Date()) -> SteamCDNServer? {
        lock.lock(); defer { lock.unlock() }
        guard !hosts.isEmpty else { return nil }
        // More servers once the ones in use each have plenty waiting.
        let waiting = hosts.reduce(0) { $0 + (entries[$1.host]?.inFlight ?? 0) }
        if active < hosts.count, waiting > active * 6 { active += 1 }
        // The directory's order is a guess about this network: once it listed only six slow, busy servers of one far-off site first and the nearer ones, which were ten times
        // faster for the same device a day later, never got a turn. So now and then (often at the start, seldom later) one request goes to a server outside the ones in
        // use that has not been tried; once it has shown its speed it competes with the rest on that speed.
        chooses += 1
        let probeEvery = chooses < 600 ? 40 : 200
        if chooses % probeEvery == 0,
           let outsider = hosts.dropFirst(active).first(where: { (entries[$0.host]?.requests ?? 0) == 0 && (entries[$0.host]?.sitOutUntil ?? .distantPast) <= now }) {
            entries[outsider.host, default: Entry()].inFlight += 1
            return outsider
        }
        let pool = Array(hosts.prefix(active)) + hosts.dropFirst(active).filter { (entries[$0.host]?.speed ?? 0) > 0 }
        var usable = pool.filter { (entries[$0.host]?.sitOutUntil ?? .distantPast) <= now }
        if usable.isEmpty { usable = hosts.filter { (entries[$0.host]?.sitOutUntil ?? .distantPast) <= now } }
        if usable.isEmpty { usable = pool }
        let known = entries.values.map(\.speed).filter { $0 > 0 }
        let untried = max(known.max() ?? 0, Double(8 << 20))                // a server not tried yet counts as good, so it gets a turn
        var best = usable[0], bestScore = -1.0
        for host in usable {
            let entry = entries[host.host] ?? Entry()
            let score = (entry.speed > 0 ? entry.speed : untried) / Double(1 + entry.inFlight)
            if score > bestScore { best = host; bestScore = score }
        }
        entries[best.host, default: Entry()].inFlight += 1
        return best
    }

    /// The request to `host` ended: `bytes` came in `seconds` (ok), or it failed.
    func finished(host: String, bytes: Int, seconds: Double, ok: Bool, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var entry = entries[host] ?? Entry()
        entry.inFlight = max(0, entry.inFlight - 1)
        entry.requests += 1
        if ok {
            if seconds > 0.001 {
                let rate = Double(bytes) / seconds
                entry.speed = entry.speed == 0 ? rate : entry.speed * 0.7 + rate * 0.3
                entry.bytes += UInt64(bytes); entry.seconds += seconds
            }
        } else {
            entry.failures += 1
            entry.speed *= 0.5
            entry.sitOutUntil = now.addingTimeInterval(min(30, Double(1 << min(entry.failures, 5))))
        }
        entries[host] = entry
    }

    /// For the log: the busiest servers with the speed of an average request to each.
    func summary(top: Int = 5) -> String {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.value.requests > 0 }.sorted { $0.value.requests > $1.value.requests }.prefix(top).map { name, e in
            let short = name.replacingOccurrences(of: ".steamcontent.com", with: "")
            let rate = e.seconds > 0 ? Double(e.bytes) / e.seconds / 1_048_576 : 0
            return String(format: "%@=%.1fMB/s(n=%d%@)", short, rate, e.requests, e.failures > 0 ? ",\(e.failures) failed" : "")
        }.joined(separator: " ") + " | servers in use \(active) of \(hosts.count), sites: " + Set(hosts.map { Self.site(of: $0.host) }).sorted().joined(separator: ",")
    }

    /// For tests: how many requests are waiting on a server.
    func waiting(on host: String) -> Int { lock.lock(); defer { lock.unlock() }; return entries[host]?.inFlight ?? 0 }
}
