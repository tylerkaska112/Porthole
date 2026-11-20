// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import GameController

/// Settings > Controls > Test controller: what a connected controller is doing right now, drawn, so a person can see that every button and stick works, whether a stick drifts, and set
/// a deadzone that holds a drifting stick at its centre in games and in Porthole's own menus (StickDeadzone). Nothing here reaches a game.

// MARK: - What the controller says

enum PadButton: String, CaseIterable, Hashable {
    case a, b, x, y, lb, rb, leftStick, rightStick, menu, view, home, up, down, left, right
}

/// One reading of one controller: the sticks as the controller reports them (before any deadzone), the triggers, and the buttons held.
struct PadReading: Equatable {
    var name: String
    var kind: ControllerKind
    var key: String                       // what its deadzone is kept under (StickDeadzone.key)
    var lx: Float = 0, ly: Float = 0, rx: Float = 0, ry: Float = 0
    var lt: Float = 0, rt: Float = 0
    var held: Set<PadButton> = []
    var hasHome = false, hasView = false

    /// Every connected controller with an extended gamepad, the way the game and the menus see them.
    static func liveAll() -> [PadReading] {
        GCController.controllers().compactMap { c -> PadReading? in
            guard let pad = c.extendedGamepad else { return nil }
            let kind = ControllerKind.classify(productCategory: c.productCategory, vendorName: c.vendorName ?? "", dualSenseProfile: pad is GCDualSenseGamepad,
                                               dualShockProfile: pad is GCDualShockGamepad, xboxProfile: pad is GCXboxGamepad)
            var r = PadReading(name: c.vendorName ?? kind.displayName, kind: kind, key: StickDeadzone.key(vendor: c.vendorName, category: c.productCategory))
            r.lx = pad.leftThumbstick.xAxis.value; r.ly = pad.leftThumbstick.yAxis.value
            r.rx = pad.rightThumbstick.xAxis.value; r.ry = pad.rightThumbstick.yAxis.value
            r.lt = pad.leftTrigger.value; r.rt = pad.rightTrigger.value
            r.hasHome = pad.buttonHome != nil; r.hasView = pad.buttonOptions != nil
            let all: [(PadButton, GCControllerButtonInput?)] = [
                (.a, pad.buttonA), (.b, pad.buttonB), (.x, pad.buttonX), (.y, pad.buttonY), (.lb, pad.leftShoulder), (.rb, pad.rightShoulder),
                (.leftStick, pad.leftThumbstickButton), (.rightStick, pad.rightThumbstickButton), (.menu, pad.buttonMenu), (.view, pad.buttonOptions), (.home, pad.buttonHome),
                (.up, pad.dpad.up), (.down, pad.dpad.down), (.left, pad.dpad.left), (.right, pad.dpad.right),
            ]
            for (button, input) in all where input?.isPressed == true { r.held.insert(button) }
            return r
        }
    }
}

// MARK: - The model

@MainActor final class PadTestModel: ObservableObject {
    @Published private(set) var pads: [PadReading] = []
    @Published var selected = 0
    @Published private(set) var drift: Drift = .idle
    /// A button pressed at some point since the page opened, so a quick tap is not missed.
    @Published private(set) var everPressed: Set<PadButton> = []
    /// 0...1 while the menu button is held to leave the page (the page takes the controller, so a button cannot be used for going back).
    @Published private(set) var leaveProgress = 0.0
    @Published private(set) var leaveRequested = false
    private var menuSince: Date?
    static let leaveSeconds = 1.0

    enum Drift: Equatable {
        case idle
        case sampling(Double)
        case done(left: Double, right: Double)
        case failed(String)
    }

    private let source: () -> [PadReading]
    private var timer: Timer?
    private var started: Date?
    private var left: [(x: Float, y: Float)] = [], right: [(x: Float, y: Float)] = []
    static let checkSeconds = 2.0

    init(source: @escaping () -> [PadReading] = PadReading.liveAll) { self.source = source }

    var current: PadReading? { pads.indices.contains(selected) ? pads[selected] : nil }

    func start() {
        guard timer == nil else { return }
        leaveRequested = false; leaveProgress = 0; menuSince = nil
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    func stop() { timer?.invalidate(); timer = nil; if case .sampling = drift { drift = .idle } }

    func clearPresses() { everPressed = [] }

    private func trackLeave(held: Bool) {
        guard held else { menuSince = nil; if leaveProgress != 0 { leaveProgress = 0 }; return }
        let since = menuSince ?? Date()
        menuSince = since
        leaveProgress = min(1, Date().timeIntervalSince(since) / Self.leaveSeconds)
        if leaveProgress >= 1, !leaveRequested { leaveRequested = true }
    }

    private func tick() {
        let now = source()
        if now != pads { pads = now }
        if !pads.indices.contains(selected) { selected = 0 }
        guard let r = current else {
            if case .sampling = drift { drift = .failed("The controller went away.") }
            return
        }
        let pressed = everPressed.union(r.held)
        if pressed != everPressed { everPressed = pressed }
        trackLeave(held: r.held.contains(.menu))
        guard let started else { return }
        left.append((r.lx, r.ly)); right.append((r.rx, r.ry))
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < Self.checkSeconds { drift = .sampling(elapsed / Self.checkSeconds); return }
        self.started = nil
        let l = StickDeadzone.rest(samples: left), rr = StickDeadzone.rest(samples: right)
        drift = l.released && rr.released ? .done(left: l.distance, right: rr.distance)
                                         : .failed("A stick was moving. Put the controller down, let go of both sticks and check again.")
    }

    func checkDrift() {
        guard current != nil else { return }
        left = []; right = []; started = Date(); drift = .sampling(0)
    }

    func resetDrift() { started = nil; drift = .idle }
}

// MARK: - The page

/// Settings > Controls > Test controller: the controller, big, and nothing else. A DualSense is a 3D model that moves with the real one; other controllers are the flat drawing. The sticks' dials, the
/// deadzone and the drift check are on their own page (StickSettingsContent), and the switch for following the controller's motion is in the Controller settings.
struct ControllerTestContent: View {
    @StateObject private var model: PadTestModel
    @AppStorage("f4.testPad.followMotion") private var followMotion = true
    /// What leaving the page does (the page takes the controller, so the menu button held for a second goes back; touch goes back as always).
    var onExit: () -> Void = {}

    /// `model` is for the preview, which feeds in a controller that is not there.
    init(model: (() -> PadTestModel)? = nil, onExit: @escaping () -> Void = {}) { _model = StateObject(wrappedValue: model?() ?? PadTestModel()); self.onExit = onExit }

    var body: some View {
        VStack(spacing: 10) {
            if let pad = model.current {
                if model.pads.count > 1 {
                    Picker("Controller", selection: $model.selected) {
                        ForEach(Array(model.pads.enumerated()), id: \.offset) { Text($0.element.name).tag($0.offset) }
                    }
                    .pickerStyle(.segmented)
                }
                if let model3D = PadModel3D.model(for: pad.kind) {
                    Pad3DView(model: model3D, pad: pad, everPressed: model.everPressed, followMotion: followMotion, onReset: { model.clearPresses() })
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1.05, contentMode: .fit)
                        .frame(maxHeight: 640)
                        .background(GlassFill.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    PadIllustration(pad: pad, everPressed: model.everPressed)
                        .frame(maxWidth: 560).frame(maxWidth: .infinity)
                        .padding(.horizontal, 10).padding(.vertical, 14)
                        .background(GlassFill.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                Text(model.leaveProgress > 0 ? "Leaving\u{2026}" : hint(pad))
                    .font(.footnote).foregroundStyle(model.leaveProgress > 0 ? Theme.accent : Theme.textDim)
                    .multilineTextAlignment(.center).padding(.horizontal, 6)
            } else {
                VStack(spacing: 8) {
                    Label("No controller", systemImage: "gamecontroller").font(.headline)
                    Text("Pair a controller in the iOS Bluetooth settings (or plug it in), then press any button on it.").font(.callout).foregroundStyle(Theme.textDim)
                }
                .padding(18).frame(maxWidth: .infinity)
                .background(GlassFill.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .onAppear { ControllerInput.shared.capture(true); model.start() }
        .onDisappear { model.stop(); ControllerInput.shared.capture(false) }
        .onChange(of: model.leaveRequested) { _, now in if now { onExit() } }
    }

    private func hint(_ pad: PadReading) -> String {
        let leave = "To leave, hold \(pad.kind.glyph("Menu")) for a second, or touch Back."
        guard let model3D = PadModel3D.model(for: pad.kind) else { return "Press everything: what you press lights up. \(leave)" }
        return model3D.hasMotion ? "Drag to turn it, pinch to zoom, double-tap to reset the view and the motion. \(leave)" : "Drag to turn it, pinch to zoom, double-tap to reset the view. \(leave)"
    }
}

/// Settings > Controls > Sticks and drift: the two sticks as big dials, a deadzone for each, and a check for drift. (The Test controller page shows the controller and nothing else.)
struct StickSettingsContent: View {
    @StateObject private var model: PadTestModel
    @State private var setting = StickDeadzone.Setting()
    /// What leaving the page does (the page takes the controller, so the menu button held for a second goes back; touch goes back as always).
    var onExit: () -> Void = {}

    /// `model` is for the preview, which feeds in a controller that is not there.
    init(model: (() -> PadTestModel)? = nil, onExit: @escaping () -> Void = {}) { _model = StateObject(wrappedValue: model?() ?? PadTestModel()); self.onExit = onExit }

    var body: some View {
        Group {
            if let pad = model.current {
                connected(pad)
            } else {
                SettingsGroup(title: "No controller", note: "Connect one to check its sticks.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Pair a controller in the iOS Bluetooth settings (or plug it in), then press any button on it.", systemImage: "gamecontroller")
                            .font(.callout).foregroundStyle(Theme.textDim)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(GlassFill.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .onAppear { ControllerInput.shared.capture(true); model.start() }
        .onDisappear { model.stop(); ControllerInput.shared.capture(false) }
        .onChange(of: model.leaveRequested) { _, now in if now { onExit() } }
    }

    @ViewBuilder private func connected(_ pad: PadReading) -> some View {
        SettingsGroup(title: "Sticks", note: "The dot is where the stick is. A stick that rests off the centre moves a game's camera by itself: set a deadzone a little above how far it rests, and the shaded circle shows what is ignored.") {
            HStack(alignment: .top, spacing: 14) {
                stickPanel("Left stick", pad: pad, right: false)
                stickPanel("Right stick", pad: pad, right: true)
            }
            .padding(14)
            .background(GlassFill.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !StickDeadzone.Store.shared.setting(for: pad.key).isDefault || !setting.isDefault {
                PillButton(id: "dz-reset", title: "Back to no deadzone", symbol: "arrow.counterclockwise") {
                    StickDeadzone.Store.shared.set(.init(), for: pad.key); setting = .init()
                }
            }
        }
        .onAppear { setting = StickDeadzone.Store.shared.setting(for: pad.key) }
        SettingsGroup(title: "Check for drift", note: "Put the controller down, let go of both sticks and check. It also works while a deadzone is set.") {
            driftCard(pad)
        }
    }

    /// One stick: the big dial, its numbers, and the deadzone for it, together, because that is where drift is judged.
    private func stickPanel(_ title: String, pad: PadReading, right: Bool) -> some View {
        let zone = StickDeadzone.Store.shared.setting(for: pad.key).zone(right: right)
        return VStack(spacing: 8) {
            StickDial(title: title, x: right ? pad.rx : pad.lx, y: right ? pad.ry : pad.ly, zone: zone,
                      clicked: pad.held.contains(right ? .rightStick : .leftStick), everClicked: model.everPressed.contains(right ? .rightStick : .leftStick))
            VStack(spacing: 2) {
                HStack {
                    Text("Deadzone").font(.caption).foregroundStyle(Theme.textDim)
                    Spacer()
                    Text("\(Int((zone * 100).rounded()))%").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(zone > 0 ? Theme.accent : Theme.textDim)
                }
                Slider(value: binding(pad, right: right), in: 0...StickDeadzone.maximum, step: 0.01).tint(Theme.accent)
                    .accessibilityLabel("\(title) deadzone")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func binding(_ pad: PadReading, right: Bool) -> Binding<Double> {
        Binding(get: { StickDeadzone.Store.shared.setting(for: pad.key).zone(right: right) },
                set: { value in
                    var s = StickDeadzone.Store.shared.setting(for: pad.key)
                    if right { s.right = value } else { s.left = value }
                    StickDeadzone.Store.shared.set(s, for: pad.key); setting = s
                })
    }

    @ViewBuilder private func driftCard(_ pad: PadReading) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.drift {
            case .idle:
                Text("Takes two seconds.").font(.callout).foregroundStyle(Theme.textDim)
                PillButton(id: "drift-check", title: "Check for drift", symbol: "scope", style: .primary) { model.checkDrift() }
            case .sampling(let progress):
                Text("Keep your hands off the sticks\u{2026}").font(.callout)
                ProgressView(value: progress).tint(Theme.accent)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.warn)
                PillButton(id: "drift-again", title: "Check again", symbol: "arrow.clockwise") { model.checkDrift() }
            case .done(let left, let right):
                driftRow("Left stick", rest: left, rightSide: false, pad: pad)
                driftRow("Right stick", rest: right, rightSide: true, pad: pad)
                PillButton(id: "drift-again", title: "Check again", symbol: "arrow.clockwise") { model.checkDrift() }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassFill.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func driftRow(_ title: String, rest: Double, rightSide: Bool, pad: PadReading) -> some View {
        let verdict = StickDeadzone.verdict(rest: rest)
        let suggested = StickDeadzone.suggestion(rest: rest)
        let current = StickDeadzone.Store.shared.setting(for: pad.key).zone(right: rightSide)
        let color: Color = verdict == .centred ? Theme.good : verdict == .slight ? Theme.warn : Theme.bad
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: verdict == .centred ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(color)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Text(verdict.title).font(.callout).foregroundStyle(color)
            }
            Text("Rests \(Int((rest * 100).rounded()))% off the centre.").font(.footnote).foregroundStyle(Theme.textDim)
            if verdict != .centred, suggested > current + 0.004 {
                PillButton(id: "drift-set-\(rightSide)", title: "Set deadzone to \(Int((suggested * 100).rounded()))%", symbol: "circle.dashed") {
                    var s = StickDeadzone.Store.shared.setting(for: pad.key)
                    if rightSide { s.right = suggested } else { s.left = suggested }
                    StickDeadzone.Store.shared.set(s, for: pad.key); setting = s
                }
            } else if verdict != .centred {
                Text("Your deadzone of \(Int((current * 100).rounded()))% already covers it.").font(.footnote).foregroundStyle(Theme.good)
            }
        }
    }
}

// MARK: - Names

enum PadNames {
    /// A button's name as printed on this controller.
    static func name(_ button: PadButton, kind: ControllerKind) -> String {
        switch button {
        case .a: kind.glyph("A")
        case .b: kind.glyph("B")
        case .x: kind.glyph("X")
        case .y: kind.glyph("Y")
        case .lb: kind.glyph("LB")
        case .rb: kind.glyph("RB")
        case .leftStick: "Left stick click"
        case .rightStick: "Right stick click"
        case .menu: kind.glyph("Menu")
        case .view: kind.glyph("View")
        case .home: "Home"
        case .up: "D-pad up"
        case .down: "D-pad down"
        case .left: "D-pad left"
        case .right: "D-pad right"
        }
    }
}

// MARK: - The big dials

/// A stick: the dot is where it is. The shaded disc is the deadzone; the ring shows the raw push when a deadzone changes what a game sees (the filled dot).
struct StickDial: View {
    let title: String
    let x: Float
    let y: Float
    let zone: Double
    let clicked: Bool
    let everClicked: Bool

    private var processed: (x: Float, y: Float) { StickDeadzone.apply(x: x, y: y, zone: zone) }

    var body: some View {
        let shown = processed
        VStack(spacing: 6) {
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                let radius = size / 2 - 10
                ZStack {
                    Circle().fill(Theme.panelHigh.opacity(0.6))
                    Circle().stroke(clicked ? Theme.accent : (everClicked ? Theme.accent.opacity(0.7) : Theme.line), lineWidth: clicked ? 4 : (everClicked ? 2 : 1))
                    Path { p in
                        p.move(to: CGPoint(x: size / 2, y: 6)); p.addLine(to: CGPoint(x: size / 2, y: size - 6))
                        p.move(to: CGPoint(x: 6, y: size / 2)); p.addLine(to: CGPoint(x: size - 6, y: size / 2))
                    }
                    .stroke(Theme.line, lineWidth: 1)
                    if zone > 0 {
                        Circle().fill(Theme.accent.opacity(0.18)).frame(width: radius * 2 * CGFloat(zone), height: radius * 2 * CGFloat(zone))
                        Circle().stroke(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: radius * 2 * CGFloat(zone), height: radius * 2 * CGFloat(zone))
                    }
                    Circle().stroke(Theme.text, lineWidth: 2).frame(width: 14, height: 14)
                        .offset(x: CGFloat(x) * radius, y: -CGFloat(y) * radius)
                    if zone > 0 {
                        Circle().fill(Theme.accent).frame(width: 12, height: 12)
                            .offset(x: CGFloat(shown.x) * radius, y: -CGFloat(shown.y) * radius)
                    } else {
                        Circle().fill(Theme.text).frame(width: 8, height: 8)
                            .offset(x: CGFloat(x) * radius, y: -CGFloat(y) * radius)
                    }
                }
                .frame(width: size, height: size)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 150)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
            Text(String(format: "X %+.2f  Y %+.2f", x, y)).font(.caption.monospacedDigit())
            if zone > 0 {
                Text(String(format: "Game: X %+.2f  Y %+.2f", shown.x, shown.y)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(String(format: "x %.2f, y %.2f", x, y))
    }
}
