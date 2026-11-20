// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// A simple way to keep a call's own sound out of the microphone when the speakers are loud: while other people are being played, a microphone frame that is not clearly louder than
/// what the speakers are playing is taken for their sound coming back (an echo) and is not sent. It is not an echo canceller (that needs the device's own voice processing, which the
/// game's audio engine cannot share): the price is that you are not heard over somebody who is louder than you. Pure arithmetic, so it is tested without audio.
struct EchoSuppressor {
    /// The loudness (RMS) of what the speakers are playing: it rises at once and falls by `decay` every microphone frame (20 ms), which is the room's tail.
    private(set) var playback: Float = 0
    static let decay: Float = 0.82
    /// Below this the speakers are practically silent: nothing can echo.
    static let floor: Float = 0.004
    /// A frame is an echo when the microphone is not louder than this share of the speakers.
    static let ratio: Float = 1.0

    /// A frame of the call was played at this loudness (after its volume setting).
    mutating func played(rms: Float) { playback = max(playback, rms) }

    /// One microphone frame has gone by: the level falls.
    mutating func tick() {
        playback *= Self.decay
        if playback < 0.0001 { playback = 0 }
    }

    /// Whether a microphone frame of this loudness is the speakers' own sound.
    func isEcho(micRMS: Float) -> Bool { playback > Self.floor && micRMS < playback * Self.ratio }

    /// The loudness (RMS) of a block of samples.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}
