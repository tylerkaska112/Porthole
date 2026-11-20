// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// How long a picture takes from the moment the game asks the screen for it until it is on the screen, and how often the game makes one. Foundation only; PresentTimer feeds it from the screen layer.
///
/// Every picture is timed on its own: when the game asked for it (before any wait for a free screen buffer, which is where a queue shows) and when it was shown. With frame generation a game frame is
/// several pictures (the generated ones and the real one, shown last, with the longest delay), so the caller says how many pictures make a game frame: the delay of a frame is that of its real
/// picture, the slowest 1/K of the pictures, and the game's frame time is K times the time between pictures.
struct PresentTimingTracker {
    static let keep = 240
    /// Only pictures asked for within this many seconds count.
    static let window = 2.0
    /// A picture that was asked for and never shown (dropped) is forgotten after this long.
    static let stale = 1.0
    /// A gap this long between pictures is a pause (a loading screen), and what came before it does not count.
    static let pause = 0.5
    /// Fewest pictures a number is worked out from.
    static let fewest = 6

    private var open: [UInt64: Double] = [:]
    private var pictures: [(asked: Double, delay: Double)] = []

    /// The game asked for picture `id` at `now`.
    mutating func asked(_ id: UInt64, at now: Double) {
        open[id] = now
        if open.count > 64 { for (k, t) in open where now - t > Self.stale { open[k] = nil } }
    }

    /// Picture `id` is on the screen at `now`.
    mutating func shown(_ id: UInt64, at now: Double) {
        guard let t = open.removeValue(forKey: id) else { return }
        pictures.append((t, now - t))
        if pictures.count > Self.keep { pictures.removeFirst(pictures.count - Self.keep) }
    }

    mutating func reset() { self = PresentTimingTracker() }

    /// The pictures asked for in the last two seconds, oldest first, after the last pause.
    private func recent(now: Double) -> [(asked: Double, delay: Double)] {
        var r = pictures.filter { now - $0.asked <= Self.window }.sorted { $0.asked < $1.asked }
        if let cut = (1..<max(r.count, 1)).last(where: { r[$0].asked - r[$0 - 1].asked > Self.pause }) { r = Array(r[cut...]) }
        return r
    }

    private static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The game's frame time in milliseconds: the time between pictures times the number of pictures in a frame.
    func frameMs(now: Double, picturesPerFrame: Int = 1) -> Double? {
        let r = recent(now: now)
        guard r.count >= Self.fewest, let first = r.first, let last = r.last, last.asked > first.asked else { return nil }
        return (last.asked - first.asked) / Double(r.count - 1) * Double(max(1, picturesPerFrame)) * 1000
    }

    /// How long the game's picture takes to reach the screen, in milliseconds: the middle of the slowest 1/K of the pictures (the real ones).
    func screenMs(now: Double, picturesPerFrame: Int = 1) -> Double? {
        let r = recent(now: now)
        guard r.count >= Self.fewest else { return nil }
        let k = max(1, picturesPerFrame)
        let slowest = r.map(\.delay).sorted(by: >).prefix(max(1, (r.count + k - 1) / k))
        return Self.median(Array(slowest)).map { $0 * 1000 }
    }
}

/// The input lag a player feels, put together from what is measured: a press waits on average half a game frame for the game to start the next one, the game spends about one frame on it, and
/// then the picture takes its time to reach the screen (the game's frame queue, the screen's refresh). With frame generation making pictures, the real one is also held back about half a game frame
/// so the generated ones can be shown first. The reading of the controller (a few milliseconds) is added when it has been measured. An estimate, not a measurement of one press.
enum InputLagEstimate {
    static func milliseconds(frameMs: Double?, screenMs: Double?, readMs: Double?, generating: Bool = false) -> Double? {
        guard let frameMs, let screenMs else { return nil }
        return (readMs ?? 0) + 1.5 * frameMs + screenMs + (generating ? 0.5 * frameMs : 0)
    }
}
