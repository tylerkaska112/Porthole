// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// How loud each person in a call is for this phone alone, and who is muted. Remembered by Discord user id, so the same person is just as loud in the next call.
/// Only what differs from normal (100 %, not muted) is kept.
struct PersonVolumes: Equatable {
    static let volumeKey = "f4.discord.personVolumes", mutedKey = "f4.discord.personMuted"
    static let range: ClosedRange<Double> = 0...200

    private(set) var percent: [String: Double] = [:]
    private(set) var muted: Set<String> = []

    func volume(_ id: String) -> Double { percent[id] ?? 100 }
    func isMuted(_ id: String) -> Bool { muted.contains(id) }
    /// What to multiply this person's sound by (0 when muted).
    func gain(_ id: String) -> Float { isMuted(id) ? 0 : Float(volume(id) / 100) }

    /// The gain of everybody who is not at normal; anybody not in it plays at normal.
    var gains: [String: Float] {
        var all: [String: Float] = [:]
        for id in Set(percent.keys).union(muted) { all[id] = gain(id) }
        return all
    }

    mutating func setVolume(_ id: String, _ value: Double) {
        let v = min(max(value.rounded(), Self.range.lowerBound), Self.range.upperBound)
        if v == 100 { percent[id] = nil } else { percent[id] = v }
    }

    mutating func setMuted(_ id: String, _ on: Bool) {
        if on { muted.insert(id) } else { muted.remove(id) }
    }

    static func load(_ defaults: UserDefaults = .standard) -> PersonVolumes {
        var p = PersonVolumes()
        for (id, v) in defaults.dictionary(forKey: volumeKey) as? [String: Double] ?? [:] { p.setVolume(id, v) }
        for id in defaults.stringArray(forKey: mutedKey) ?? [] { p.setMuted(id, true) }
        return p
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(percent, forKey: Self.volumeKey)
        defaults.set(Array(muted).sorted(), forKey: Self.mutedKey)
    }
}
