// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// Controller rumble. A game asks for vibration through XInput (XInputSetState: a left, heavy motor and a right, light motor, 0 to 65535 each). The engine's XInput DLLs hand those
// values to win32u, which stores them in the Winios gamepad state (winios_gamepad_set_vibration, Madeira's own since the engine update of 2026-10); the engine then calls the notify
// hook registered below, and this plays the stored values on the matching controller's haptic engines (left and right handle, so the two motors feel different). Nothing happens
// without a controller that has haptics. The strength is a setting (Settings > Engine options > Controller rumble); "Off" also tells games the pad has no motors.
import Foundation
import CoreHaptics
@preconcurrency import GameController

final class PadRumble: @unchecked Sendable {
    static let shared = PadRumble()

    /// One motor: a running haptic engine and, while the game wants it, a timer that plays a short buzz at the requested strength every ~90 ms (a one-shot
    /// pattern is the thing that is known to play on a DualSense; the looping pattern whose strength is changed live would not even start).
    private final class Motor {
        var engine: CHHapticEngine?
        var timer: DispatchSourceTimer?
        var level: Float = 0
        var side = 0
    }

    private let queue = DispatchQueue(label: "porthole.rumble", qos: .userInteractive)
    private var motors: [[Motor]] = (0..<4).map { _ in [Motor(), Motor()] }        // [player][0 left/heavy, 1 right/light]
    private var last = [(UInt32, UInt32)](repeating: (0, 0), count: 4)
    private var scale: Float = 1                                                    // 0 = off

    static func scale(from option: String) -> Float { RumbleMath.scale(from: option) }

    func configure(scale: Float) {
        // Games are told the pad has motors only while rumble is on (the engine reads this when a game asks for the pad's capabilities).
        winios_gamepad_set_rumble_caps(scale > 0 ? 1 : 0)
        installNotify()
        let pads = GCController.controllers().map { c in "\(c.productCategory) haptics=\(c.haptics.map { h in "[" + h.supportedLocalities.map(\.rawValue).sorted().joined(separator: ",") + "]" } ?? "none")" }
        LogStore.shared.log("[rumble] \(scale > 0 ? "on, strength \(Int(scale * 100))%" : "off"); controllers: \(pads.isEmpty ? "none connected" : pads.joined(separator: "; "))")
        queue.async { [self] in
            self.scale = scale
            if scale == 0 { stopAllLocked() }
        }
    }

    /// The engine calls this after a game's vibration request changed something (on the writer's thread, outside every lock): read all four slots and play what changed.
    private var notifyInstalled = false
    private func installNotify() {
        guard !notifyInstalled else { return }
        notifyInstalled = true
        winios_pad_output_set_notify { PadRumble.shared.pull() }
    }

    private var notifies = 0, logged = 0, lastReason = ""
    func pull() {
        notifies += 1
        for index in 0..<4 {
            var v = winios_gamepad_vibration()
            if winios_gamepad_get_vibration(Int32(index), &v) != 0 { set(index: index, left: UInt32(v.left), right: UInt32(v.right)) }
        }
    }

    /// The first few requests and the reason a request was not played, so a log shows where rumble stops (the game never asks, no controller, no haptics, or the motors fail to start).
    private func note(_ text: String) {
        guard logged < 60, text != lastReason else { return }
        logged += 1; lastReason = text
        LogStore.shared.log("[rumble] " + text)
    }

    /// A game's request, from a Wine thread. Repeated identical values (games send them every frame) cost nothing.
    func set(index: Int, left: UInt32, right: UInt32) {
        guard (0..<4).contains(index) else { return }
        queue.async { [self] in
            guard last[index] != (left, right) else { return }
            last[index] = (left, right)
            note("game asked pad \(index + 1): left \(left), right \(right) (request \(notifies))")
            guard scale > 0 else { note("rumble is off in Engine options"); return }
            guard let controller = PadInput.shared.controller(at: index) else { note("no controller in slot \(index + 1) (HID mode, or the pad is not handed to the game)"); return }
            guard controller.haptics != nil else { note("this controller has no haptics (\(controller.productCategory))"); return }
            drive(controller, index: index, side: 0, level: Self.level(left, scale))
            drive(controller, index: index, side: 1, level: Self.level(right, scale))
        }
    }

    static func level(_ speed: UInt32, _ scale: Float) -> Float { RumbleMath.level(speed, scale) }

    /// Everything off (the game ended, the app went to the background, or a controller left).
    func stopAll() { queue.async { [self] in stopAllLocked() } }

    private func stopAllLocked() {
        for i in 0..<4 { for side in 0..<2 { silence(motors[i][side]) }; last[i] = (0, 0) }
    }

    private func silence(_ m: Motor) {
        m.level = 0
        m.timer?.cancel(); m.timer = nil
    }

    private func drive(_ controller: GCController, index: Int, side: Int, level: Float) {
        let m = motors[index][side]
        if level < 0.005 { silence(m); return }
        m.level = level; m.side = side
        if m.engine == nil, let error = buildEngine(m, controller: controller, side: side) { note("haptic engine: " + error); return }
        guard m.timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(90))
        t.setEventHandler { [weak self, weak m] in guard let self, let m else { return }; if let error = self.pulse(m) { self.note("motor: " + error); self.silence(m); m.engine = nil } }
        m.timer = t
        t.resume()
    }

    /// Gets the motor's haptic engine running. Returns an error text, or nil when it is ready.
    private func buildEngine(_ m: Motor, controller: GCController, side: Int) -> String? {
        guard let haptics = controller.haptics else { return "the controller has no haptics" }
        let locality: GCHapticsLocality = side == 0 ? .leftHandle : .rightHandle
        guard let engine = haptics.createEngine(withLocality: locality) ?? haptics.createEngine(withLocality: .default) else { return "no engine for \(locality.rawValue)" }
        do {
            engine.stoppedHandler = { [weak m] _ in m?.engine = nil }
            engine.resetHandler = { try? engine.start() }
            try engine.start()
            m.engine = engine
            return nil
        } catch { return ErrorText.plain(error) }
    }

    /// One short buzz at the motor's current strength; the heavy motor is a low rumble, the light one a sharper buzz. Returns an error text, or nil.
    private func pulse(_ m: Motor) -> String? {
        guard m.level > 0.005, let engine = m.engine else { return nil }
        do {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: m.level),
                                                                                 CHHapticEventParameter(parameterID: .hapticSharpness, value: m.side == 0 ? 0.15 : 0.85)], relativeTime: 0, duration: 0.12)
            let player = try engine.makePlayer(with: try CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            return nil
        } catch { return ErrorText.plain(error) }
    }

    /// A short buzz on the first connected controller, for the Engine options page, with the outcome of every step spelled out (`done` gets the text, on the main queue).
    /// Plain one-shot patterns first (does the controller buzz at all?), then the way a game's rumble is played (a looping pattern whose strength is changed live).
    func test(done: @escaping (String) -> Void) {
        let controllers = GCController.controllers()
        guard let controller = controllers.first(where: { $0.haptics != nil }) else {
            let text = controllers.isEmpty ? "No controller is connected to this app." : "Connected (\(controllers.map(\.productCategory).joined(separator: ", "))) but with no haptics."
            LogStore.shared.log("[rumble] test: " + text); done(text); return
        }
        queue.async { [self] in
            var out: [String] = []
            let haptics = controller.haptics!
            out.append("\(controller.productCategory); localities: " + haptics.supportedLocalities.map(\.rawValue).sorted().joined(separator: ", "))
            for (name, locality) in [("all", GCHapticsLocality.all), ("left", .leftHandle), ("right", .rightHandle)] {
                guard let engine = haptics.createEngine(withLocality: locality) else { out.append("\(name): no engine"); continue }
                do {
                    try engine.start()
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                                                         CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)], relativeTime: 0, duration: 0.5)
                    let player = try engine.makePlayer(with: try CHHapticPattern(events: [event], parameters: []))
                    try player.start(atTime: CHHapticTimeImmediate)
                    out.append("\(name): played")
                    Thread.sleep(forTimeInterval: 0.65)
                } catch { out.append("\(name): \(ErrorText.plain(error))") }
                engine.stop()
                Thread.sleep(forTimeInterval: 0.15)
            }
            // The path a game's rumble takes.
            let m = Motor()
            if let error = buildEngine(m, controller: controller, side: 0) { out.append("as a game: \(error)") }
            else {
                m.level = 0.9
                var failure: String?
                for _ in 0..<7 { if let e = pulse(m) { failure = e; break }; Thread.sleep(forTimeInterval: 0.09) }
                out.append(failure.map { "as a game: \($0)" } ?? "as a game: played")
                Thread.sleep(forTimeInterval: 0.2)
            }
            m.engine?.stop()
            let text = out.joined(separator: " \u{00B7} ")
            LogStore.shared.log("[rumble] test: " + text)
            DispatchQueue.main.async { done(text) }
        }
    }
}
