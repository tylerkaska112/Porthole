// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// Game details > Gyro aim and turbo (PadAssist.swift, the logic from Madeira): per game, off until turned on.
import SwiftUI

struct PadAssistGroup: View {
    @Binding var settings: PadAssistSettings?

    private func bind<T>(_ path: WritableKeyPath<PadAssistSettings, T>) -> Binding<T> {
        Binding(get: { (settings ?? PadAssistSettings())[keyPath: path] },
                set: { var next = settings ?? PadAssistSettings(); next[keyPath: path] = $0; settings = next == PadAssistSettings() ? nil : next })
    }

    private func turboBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { settings?.turbo.contains(name) == true }, set: { on in
            var next = settings ?? PadAssistSettings()
            next.turbo.removeAll { $0 == name }
            if on { next.turbo.append(name) }
            settings = next == PadAssistSettings() ? nil : next
        })
    }

    var body: some View {
        SettingsGroup(title: "Gyro aim") {
            ToggleRow(id: "pa-gyro", symbol: "gyroscope", title: "Gyro aim",
                      info: "Moving the controller (or this device) aims. Automatic gyro uses the controller's sensors (DualSense, DualShock 4, Switch Pro) and the device's own otherwise. Automatic output moves the right stick, or the mouse when the game gets no controller from the pad.",
                      isOn: bind(\.gyro))
            if settings?.gyro == true {
                ChoiceRow(id: "pa-source", symbol: "dot.radiowaves.left.and.right", title: "Gyro from", options: [(PadAssistSettings.Source.auto, "Automatic"), (.controller, "Controller"), (.device, "This device")], selection: bind(\.source))
                ChoiceRow(id: "pa-when", symbol: "hand.tap", title: "Active", options: [(PadAssistSettings.When.always, "Always"), (.lt, "While holding LT"), (.lb, "While holding LB"), (.rb, "While holding RB")], selection: bind(\.when))
                ChoiceRow(id: "pa-output", symbol: "arrow.up.left.and.arrow.down.right", title: "Moves", options: [(PadAssistSettings.Output.auto, "Automatic"), (.stick, "Right stick"), (.mouse, "Mouse")], selection: bind(\.output))
                ChoiceRow(id: "pa-turn", symbol: "arrow.left.and.right", title: "Turn with", options: [(PadAssistSettings.Turn.yaw, "Twist (yaw)"), (.roll, "Tilt (roll)")], selection: bind(\.turn))
                SliderRow(id: "pa-sens", symbol: "speedometer", title: "Sensitivity", value: bind(\.sensitivity), range: 0.25...4, step: 0.05, format: { String(format: "%.2g\u{00D7}", $0) })
                SliderRow(id: "pa-dead", symbol: "circle.dashed", title: "Anti-dead zone", info: "The least stick push a slow movement gives, so it gets past the game's own dead zone. Raise it if slow aiming does nothing.",
                          value: bind(\.antiDeadzone), range: 0...0.5, step: 0.01, format: { "\(Int(($0 * 100).rounded()))%" })
                ToggleRow(id: "pa-invy", symbol: "arrow.up.and.down", title: "Invert up and down", isOn: bind(\.invertY))
                ToggleRow(id: "pa-invx", symbol: "arrow.left.and.right", title: "Invert left and right", isOn: bind(\.invertX))
            }
        }
        SettingsGroup(title: "Turbo") {
            ForEach(PadAssistSettings.turboChoices, id: \.self) { name in
                ToggleRow(id: "pa-turbo-\(name)", symbol: "bolt.fill", title: "Turbo \(name)",
                          info: name == PadAssistSettings.turboChoices.first ? "A turbo button repeats while you hold it, on the controller and on touch controls." : nil,
                          isOn: turboBinding(name))
            }
            if settings?.turbo.isEmpty == false {
                SliderRow(id: "pa-turbo-rate", symbol: "metronome", title: "Presses a second", value: bind(\.turboRate), range: 5...30, step: 1, format: { "\(Int($0))" })
            }
        }
    }
}
