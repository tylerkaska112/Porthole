// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Part of the performance overlay's "Input lag": follows a press of the on-screen controller (or a real one) and measures how long the game takes to read it. (The delay after that is
/// PresentTimer's.) It costs nothing while the overlay does not show it, and while it does it only watches between a press and the read: a 1 ms timer that reads two counters.
final class InputLagMeter: @unchecked Sendable {
    static let shared = InputLagMeter()
    private let lock = NSLock()
    private var tracker = InputLagTracker()
    private var last = PadSnapshot()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "porthole.input-lag", qos: .userInteractive)
    private var isActive = false

    /// The overlay shows the number: measure. Turning it off forgets what was measured.
    var active: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isActive }
        set {
            lock.lock()
            guard newValue != isActive else { lock.unlock(); return }
            isActive = newValue
            if !newValue { tracker.reset(); stopTimerLocked() }
            lock.unlock()
        }
    }

    /// The latest middle values in milliseconds: the press to the game's read, and to its next picture. nil until a press has been timed.
    var medianToFrameMs: Double? { lock.lock(); defer { lock.unlock() }; return tracker.medianToFrameMs }
    var medianToReadMs: Double? { lock.lock(); defer { lock.unlock() }; return tracker.medianToReadMs }

    /// Called with every state handed to the game for player 1.
    func note(_ s: PadSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        let before = last
        last = s
        guard isActive, s.startsSomething(after: before), !tracker.isMeasuring else { return }
        tracker.begin(at: ProcessInfo.processInfo.systemUptime, reads: winios_gamepad_read_count())
        startTimerLocked()
    }

    private func startTimerLocked() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(100))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    private func stopTimerLocked() { timer?.cancel(); timer = nil }

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        let reads = winios_gamepad_read_count(), presents = madeira_shown_frame_count()
        lock.lock()
        tracker.observe(at: now, reads: reads, presents: presents)
        if !tracker.isMeasuring { stopTimerLocked() }
        lock.unlock()
    }
}
