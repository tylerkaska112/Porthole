// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// How loud the microphone has to be before it counts as talking. The setting is a percent (higher = picks up quieter sound); the sound is judged by its RMS level, and the
/// percent maps to a level on a decibel scale, so each step feels the same. 50 % is the level the app always used (0.012, about -38 dB).
enum MicSensitivity {
    static let key = "f4.discord.micSensitivity"
    static let standard = 50.0
    /// The quietest and loudest levels the meter shows, in decibels.
    static let meterFloorDB: Float = -60, meterCeilingDB: Float = -15

    static func clamp(_ percent: Double) -> Double { min(max(percent.rounded(), 0), 100) }

    static var saved: Double {
        clamp(UserDefaults.standard.object(forKey: key) as? Double ?? standard)
    }

    /// The RMS level (0...1) a frame has to pass to count as talking.
    static func threshold(percent: Double) -> Float {
        let db = -18.4 - 0.4 * Float(clamp(percent))
        return powf(10, db / 20)
    }

    /// Where an RMS level sits on the meter, 0...1.
    static func meterPosition(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10f(rms)
        return min(max((db - meterFloorDB) / (meterCeilingDB - meterFloorDB), 0), 1)
    }

    /// Where the talking threshold is drawn on the meter.
    static func thresholdPosition(percent: Double) -> Float { meterPosition(rms: threshold(percent: percent)) }
}
