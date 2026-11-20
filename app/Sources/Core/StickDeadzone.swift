// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// A stick that does not rest at its centre ("drift") moves a game's camera or a menu's selection by itself. The fix a person can make is a deadzone: every push smaller
/// than it counts as none, and what is beyond it is stretched back over the whole range, so the stick still reaches its edge and starts from zero just outside the zone.
/// Foundation only, so a host test can check it. Settings > Controls > Test controller sets it per controller; PadInput (games) and ControllerInput (menus) apply it.
enum StickDeadzone {
    static let maximum = 0.5

    /// The stick position after a round deadzone of `zone` (0...0.5). Not a square one: a diagonal push is judged by its length, so a drifting stick is never "half dead".
    static func apply(x: Float, y: Float, zone: Double) -> (x: Float, y: Float) {
        guard x.isFinite, y.isFinite else { return (0, 0) }
        let z = Float(min(max(zone, 0), maximum))
        guard z > 0 else { return (x, y) }
        let length = (x * x + y * y).squareRoot()
        guard length > z else { return (0, 0) }
        let scaled = min(1, (length - z) / (1 - z))
        return (x / length * scaled, y / length * scaled)
    }

    /// How a resting stick reads. `rest` is its largest distance from the centre while nothing touched it (0...1).
    enum Verdict: Equatable {
        case centred, slight, drifting
        var title: String {
            switch self { case .centred: "Centred"; case .slight: "Slight drift"; case .drifting: "Drifting" }
        }
    }

    static func verdict(rest: Double) -> Verdict {
        rest < 0.04 ? .centred : rest < 0.12 ? .slight : .drifting
    }

    /// The smallest deadzone that hides a stick resting `rest` away from the centre, with a margin, in whole percent.
    static func suggestion(rest: Double) -> Double {
        guard rest > 0.02 else { return 0 }
        return min(maximum, (((rest + 0.03) * 100).rounded(.up)) / 100)
    }

    /// The measurement of a rest check: the largest distance from the centre of the samples taken, and whether the stick was really let go (a push during the check ruins it).
    static func rest(samples: [(x: Float, y: Float)]) -> (distance: Double, released: Bool) {
        var worst = 0.0, spread = 0.0
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude, minY = minX, maxY = maxX
        for s in samples where s.x.isFinite && s.y.isFinite {
            worst = max(worst, Double((s.x * s.x + s.y * s.y).squareRoot()))
            minX = min(minX, s.x); maxX = max(maxX, s.x); minY = min(minY, s.y); maxY = max(maxY, s.y)
        }
        if !samples.isEmpty { spread = Double(max(maxX - minX, maxY - minY)) }
        // A thumb on the stick sweeps it around; a drifting stick sits still, a bit off.
        return (worst, worst < 0.6 && spread < 0.25)
    }

    // MARK: What each controller is set to

    struct Setting: Codable, Equatable {
        var left = 0.0
        var right = 0.0
        var isDefault: Bool { left == 0 && right == 0 }
        func zone(right isRight: Bool) -> Double { isRight ? right : left }
    }

    /// One name for a controller. Two of the same make share their setting, which is the best that iOS lets a program tell apart.
    static func key(vendor: String?, category: String?) -> String {
        let text = [vendor, category].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " / ")
        return text.isEmpty ? "controller" : text
    }

    /// The settings, kept in UserDefaults and read from memory every frame (a game reads them sixty times a second).
    final class Store: @unchecked Sendable {
        static let shared = Store()
        static let defaultsKey = "f4.stickDeadzones.v1"
        private let lock = NSLock()
        private let defaults: UserDefaults
        private var cache: [String: Setting]?

        init(defaults: UserDefaults = .standard) { self.defaults = defaults }

        private func loaded() -> [String: Setting] {
            if let cache { return cache }
            let all = (defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([String: Setting].self, from: $0) }) ?? [:]
            cache = all
            return all
        }

        func setting(for key: String) -> Setting {
            lock.lock(); defer { lock.unlock() }
            return loaded()[key] ?? Setting()
        }

        func set(_ setting: Setting, for key: String) {
            lock.lock(); defer { lock.unlock() }
            var all = loaded()
            let clean = Setting(left: min(max(setting.left, 0), maximum), right: min(max(setting.right, 0), maximum))
            if clean.isDefault { all.removeValue(forKey: key) } else { all[key] = clean }
            cache = all
            if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.defaultsKey) }
        }

        /// The stick after the deadzone this controller is set to.
        func apply(key: String, right: Bool, x: Float, y: Float) -> (x: Float, y: Float) {
            let zone = setting(for: key).zone(right: right)
            return zone > 0 ? StickDeadzone.apply(x: x, y: y, zone: zone) : (x, y)
        }
    }
}
