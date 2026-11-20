// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// What a game's controller looks like at one moment, reduced to what the input-lag meter needs.
struct PadSnapshot: Equatable {
    var buttons: UInt16 = 0
    var leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0
    var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0

    /// How far a stick is pushed, 0...1.
    private static func push(_ x: Int16, _ y: Int16) -> Double { min(1, (Double(x) * Double(x) + Double(y) * Double(y)).squareRoot() / 32767) }
    var leftPush: Double { Self.push(lx, ly) }
    var rightPush: Double { Self.push(rx, ry) }

    /// Whether going from `old` to `self` is something the game should answer visibly and worth timing: a button pressed (not released), a trigger pulled in, or a stick pushed out of its rest
    /// (a stick already pushed and only moving a little is not a new event).
    func startsSomething(after old: PadSnapshot) -> Bool {
        if buttons & ~old.buttons != 0 { return true }
        if (leftTrigger >= 100 && old.leftTrigger < 100) || (rightTrigger >= 100 && old.rightTrigger < 100) { return true }
        if (leftPush >= 0.35 && old.leftPush < 0.2) || (rightPush >= 0.35 && old.rightPush < 0.2) { return true }
        return false
    }
}

/// Times how long it takes a press to get into the game, from the two counters the runtime keeps: how many times the game has asked for the controller, and how many pictures it has presented.
///
/// A press is handed to the game at `begin`. The game reads it at its next ask for the controller (the reads counter goes up): that is the first number. The picture the game builds with it
/// is presented a little later: the first present after that read is the second. What the second one does NOT include is the time that picture waits afterwards (the game's frame queue, the
/// time frame generation holds a picture back, the screen's own refresh), and it does not see a game that smooths a stick's movement itself. It is the part of the delay Porthole and the game's
/// own frame are responsible for, so a long number here means the game reads input late, and a short one means the rest is after the game presents.
struct InputLagTracker {
    struct Measurement: Equatable {
        /// Seconds from the press to the game's next read of the controller.
        var toRead: Double
        /// Seconds from the press to the first picture the game presented after reading it.
        var toFrame: Double
    }
    private enum Stage {
        case idle
        case waitingRead(start: Double, reads: UInt64)
        case waitingFrame(start: Double, read: Double, presents: UInt64)
    }
    private var stage = Stage.idle
    /// The newest last, at most `keep`.
    private(set) var recent: [Measurement] = []
    private(set) var timedOut = 0
    static let keep = 24
    /// A press nobody answered (the game is not reading, or is not presenting) is given up after this long.
    static let timeout = 1.0

    var isMeasuring: Bool { if case .idle = stage { return false }; return true }

    /// A press has just been handed to the game. Ignored while another is being timed.
    mutating func begin(at now: Double, reads: UInt64) {
        guard !isMeasuring else { return }
        stage = .waitingRead(start: now, reads: reads)
    }

    /// The counters, polled while a press is being timed. Returns the measurement when this call completed one.
    @discardableResult
    mutating func observe(at now: Double, reads: UInt64, presents: UInt64) -> Measurement? {
        switch stage {
        case .idle:
            return nil
        case .waitingRead(let start, let startReads):
            if now - start > Self.timeout { stage = .idle; timedOut += 1; return nil }
            if reads > startReads { stage = .waitingFrame(start: start, read: now, presents: presents) }
            return nil
        case .waitingFrame(let start, let read, let seen):
            if now - start > Self.timeout { stage = .idle; timedOut += 1; return nil }
            guard presents > seen else { return nil }
            let m = Measurement(toRead: read - start, toFrame: now - start)
            stage = .idle
            recent.append(m)
            if recent.count > Self.keep { recent.removeFirst(recent.count - Self.keep) }
            return m
        }
    }

    mutating func reset() { stage = .idle; recent = []; timedOut = 0 }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    /// The middle value of the recent presses, in milliseconds (a median, so one odd press does not move it).
    var medianToFrameMs: Double? { Self.median(recent.map(\.toFrame)).map { $0 * 1000 } }
    var medianToReadMs: Double? { Self.median(recent.map(\.toRead)).map { $0 * 1000 } }
}
