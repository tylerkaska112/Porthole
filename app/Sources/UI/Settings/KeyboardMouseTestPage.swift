// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import GameController

/// Settings > Controls > Test keyboard and mouse: a keyboard drawn flat, and the keys that are held light up; a pad that shows where a mouse or trackpad moves, which of its buttons are
/// held and when the wheel turns. So a person can see that a keyboard or mouse works at all before blaming a game. Nothing here reaches a game.
/// Keys and buttons are read by looking (the game's own handlers are not touched); the mouse's movement needs a handler, so the one that is there is kept and put back.

// MARK: - The keys

struct KeySpec: Identifiable {
    let label: String
    let code: GCKeyCode
    var width: CGFloat = 1
    var id: String { label + "\(code.rawValue)" }
}

enum KeyboardLayout {
    private static func letter(_ c: Character, _ code: GCKeyCode) -> KeySpec { KeySpec(label: String(c), code: code) }

    static let rows: [[KeySpec]] = [
        [KeySpec(label: "Esc", code: .escape, width: 1.4)] + [(GCKeyCode.F1, "F1"), (.F2, "F2"), (.F3, "F3"), (.F4, "F4"), (.F5, "F5"), (.F6, "F6"), (.F7, "F7"), (.F8, "F8"),
                                                              (.F9, "F9"), (.F10, "F10"), (.F11, "F11"), (.F12, "F12")].map { KeySpec(label: $0.1, code: $0.0) },
        [KeySpec(label: "`", code: .graveAccentAndTilde)] + [(GCKeyCode.one, "1"), (.two, "2"), (.three, "3"), (.four, "4"), (.five, "5"), (.six, "6"), (.seven, "7"), (.eight, "8"),
                                                             (.nine, "9"), (.zero, "0")].map { KeySpec(label: $0.1, code: $0.0) }
            + [KeySpec(label: "-", code: .hyphen), KeySpec(label: "=", code: .equalSign), KeySpec(label: "Del", code: .deleteOrBackspace, width: 1.6)],
        [KeySpec(label: "Tab", code: .tab, width: 1.5)] + [("Q", GCKeyCode.keyQ), ("W", .keyW), ("E", .keyE), ("R", .keyR), ("T", .keyT), ("Y", .keyY), ("U", .keyU), ("I", .keyI),
                                                           ("O", .keyO), ("P", .keyP)].map { KeySpec(label: $0.0, code: $0.1) }
            + [KeySpec(label: "[", code: .openBracket), KeySpec(label: "]", code: .closeBracket), KeySpec(label: "\\", code: .backslash, width: 1.5)],
        [KeySpec(label: "Caps", code: .capsLock, width: 1.8)] + [("A", GCKeyCode.keyA), ("S", .keyS), ("D", .keyD), ("F", .keyF), ("G", .keyG), ("H", .keyH), ("J", .keyJ),
                                                                 ("K", .keyK), ("L", .keyL)].map { KeySpec(label: $0.0, code: $0.1) }
            + [KeySpec(label: ";", code: .semicolon), KeySpec(label: "'", code: .quote), KeySpec(label: "Return", code: .returnOrEnter, width: 2.2)],
        [KeySpec(label: "Shift", code: .leftShift, width: 2.3)] + [("Z", GCKeyCode.keyZ), ("X", .keyX), ("C", .keyC), ("V", .keyV), ("B", .keyB), ("N", .keyN),
                                                                   ("M", .keyM)].map { KeySpec(label: $0.0, code: $0.1) }
            + [KeySpec(label: ",", code: .comma), KeySpec(label: ".", code: .period), KeySpec(label: "/", code: .slash), KeySpec(label: "Shift", code: .rightShift, width: 2.3)],
        [KeySpec(label: "Ctrl", code: .leftControl, width: 1.4), KeySpec(label: "Opt", code: .leftAlt, width: 1.4), KeySpec(label: "Cmd", code: .leftGUI, width: 1.4),
         KeySpec(label: "Space", code: .spacebar, width: 6.2), KeySpec(label: "Cmd", code: .rightGUI, width: 1.4), KeySpec(label: "Opt", code: .rightAlt, width: 1.4),
         KeySpec(label: "Ctrl", code: .rightControl, width: 1.4)],
    ]

    static let arrows: [KeySpec] = [KeySpec(label: "\u{2190}", code: .leftArrow), KeySpec(label: "\u{2191}", code: .upArrow), KeySpec(label: "\u{2193}", code: .downArrow),
                                    KeySpec(label: "\u{2192}", code: .rightArrow)]

    static var all: [KeySpec] { rows.flatMap { $0 } + arrows }
}

// MARK: - The model

@MainActor final class KeyboardMouseTestModel: ObservableObject {
    @Published private(set) var keyboardName: String?
    @Published private(set) var held: Set<UInt> = []
    @Published private(set) var everPressed: Set<UInt> = []
    @Published private(set) var lastKey: String?
    @Published private(set) var mouseName: String?
    @Published private(set) var buttons: Set<String> = []
    @Published private(set) var everButtons: Set<String> = []
    @Published private(set) var position = CGPoint.zero            // the dot, from centre, in -1...1 of the pad
    @Published private(set) var trail: [CGPoint] = []
    @Published private(set) var moved = CGSize.zero                // everything it has moved since the page opened (points)
    @Published private(set) var wheel = 0.0                        // the turns since the page opened
    @Published private(set) var wheelFlash: Double = 0            // + up, - down: fades
    /// 0...1 while Esc is held to leave the page (the page takes the keyboard, so a key cannot be used for going back).
    @Published private(set) var leaveProgress = 0.0
    @Published private(set) var leaveRequested = false
    private var escSince: Date?
    static let leaveSeconds = 1.0

    private var timer: Timer?
    private var attached: [ObjectIdentifier: (mouse: GCMouse, moved: ((GCMouseInput, Float, Float) -> Void)?, scroll: ((GCControllerDirectionPad, Float, Float) -> Void)?)] = [:]
    private var observers: [NSObjectProtocol] = []
    private var flashAt = Date.distantPast

    func start() {
        guard timer == nil else { return }
        leaveRequested = false; leaveProgress = 0; escSince = nil
        attachMice()
        let center = NotificationCenter.default
        observers = [center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.attachMice() } },
                     center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.attachMice() } }]
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        for (_, entry) in attached {
            entry.mouse.mouseInput?.mouseMovedHandler = entry.moved
            entry.mouse.mouseInput?.scroll.valueChangedHandler = entry.scroll
        }
        attached = [:]
    }

    /// For the preview, which has no keyboard or mouse to move: shows a mouse as if it had been used.
    func showSample(buttons: Set<String>, ever: Set<String>, position: CGPoint, trail: [CGPoint], moved: CGSize, wheelFlash: Double, mouse: String) {
        mouseName = mouse; self.buttons = buttons; everButtons = ever; self.position = position; self.trail = trail; self.moved = moved; self.wheelFlash = wheelFlash
    }

    func reset() {
        everPressed = []; everButtons = []; lastKey = nil; position = .zero; trail = []; moved = .zero; wheel = 0
    }

    /// Puts our own handler in front of the one that is there, and keeps the old one to call and to put back.
    private func attachMice() {
        let mice = GCMouse.mice()
        mouseName = mice.first.map { $0.vendorName ?? "Mouse or trackpad" }
        let alive = Set(mice.map { ObjectIdentifier($0) })
        for id in attached.keys where !alive.contains(id) { attached.removeValue(forKey: id) }
        for mouse in mice where attached[ObjectIdentifier(mouse)] == nil {
            guard let input = mouse.mouseInput else { continue }
            let oldMove = input.mouseMovedHandler, oldScroll = input.scroll.valueChangedHandler
            attached[ObjectIdentifier(mouse)] = (mouse, oldMove, oldScroll)
            input.mouseMovedHandler = { [weak self] i, dx, dy in
                oldMove?(i, dx, dy)
                MainActor.assumeIsolated { self?.moved(dx: CGFloat(dx), dy: CGFloat(dy)) }
            }
            input.scroll.valueChangedHandler = { [weak self] p, x, y in
                oldScroll?(p, x, y)
                MainActor.assumeIsolated { self?.scrolled(y: Double(y)) }
            }
        }
    }

    private func moved(dx: CGFloat, dy: CGFloat) {
        guard dx.isFinite, dy.isFinite else { return }
        moved.width += dx; moved.height += dy
        // The pad is about 400 points across for the dot; the dot is held inside it. GameController's y grows upward.
        var p = CGPoint(x: position.x + dx / 400, y: position.y - dy / 400)
        p.x = min(max(p.x, -1), 1); p.y = min(max(p.y, -1), 1)
        position = p
        trail.append(p); if trail.count > 40 { trail.removeFirst(trail.count - 40) }
    }

    private func scrolled(y: Double) {
        guard y.isFinite, y != 0 else { return }
        wheel += y; wheelFlash = y > 0 ? 1 : -1; flashAt = Date()
    }

    private func tick() {
        let keyboard = GCKeyboard.coalesced
        let name = keyboard.map { $0.vendorName ?? "Keyboard" }
        if name != keyboardName { keyboardName = name }
        if let input = keyboard?.keyboardInput {
            var now = Set<UInt>()
            for key in KeyboardLayout.all where input.button(forKeyCode: key.code)?.isPressed == true { now.insert(UInt(key.code.rawValue)) }
            if now != held {
                let added = now.subtracting(held)
                held = now
                everPressed.formUnion(now)
                if let code = added.first, let key = KeyboardLayout.all.first(where: { UInt($0.code.rawValue) == code }) { lastKey = key.label }
            }
        } else if !held.isEmpty { held = [] }
        if held.contains(UInt(GCKeyCode.escape.rawValue)) {
            let since = escSince ?? Date()
            escSince = since
            leaveProgress = min(1, Date().timeIntervalSince(since) / Self.leaveSeconds)
            if leaveProgress >= 1, !leaveRequested { leaveRequested = true }
        } else { escSince = nil; if leaveProgress != 0 { leaveProgress = 0 } }
        if let input = GCMouse.current?.mouseInput ?? GCMouse.mice().first?.mouseInput {
            var now = Set<String>()
            if input.leftButton.isPressed { now.insert("Left") }
            if input.rightButton?.isPressed == true { now.insert("Right") }
            if input.middleButton?.isPressed == true { now.insert("Middle") }
            for (i, b) in (input.auxiliaryButtons ?? []).enumerated() where b.isPressed { now.insert(i == 0 ? "Back" : i == 1 ? "Forward" : "Button \(i + 4)") }
            if now != buttons { buttons = now; everButtons.formUnion(now) }
        } else if !buttons.isEmpty { buttons = [] }
        if wheelFlash != 0, Date().timeIntervalSince(flashAt) > 0.25 { wheelFlash = 0 }
    }
}

// MARK: - The page

struct KeyboardMouseTestContent: View {
    @StateObject private var model = KeyboardMouseTestModel()
    /// What leaving the page does (it keeps the keyboard to itself, so Esc held for a second goes back; touch goes back as always).
    var onExit: () -> Void = {}

    var body: some View {
        Group {
            keyboardGroup
            mouseGroup
        }
        .onAppear { ControllerInput.shared.capture(true); model.start() }
        .onDisappear { model.stop(); ControllerInput.shared.capture(false) }
        .onChange(of: model.leaveRequested) { _, now in if now { onExit() } }
    }

    private var keyboardGroup: some View {
        SettingsGroup(title: "Keyboard", note: model.keyboardName == nil ? "No keyboard connected." : "\(model.keyboardName ?? "Keyboard"). Press keys: a key that is held lights up, and one you have pressed keeps a ring. This page keeps the keyboard to itself: to leave, hold Esc for a second, or touch Back.") {
            if model.keyboardName == nil {
                emptyCard("keyboard", "Connect a keyboard by Bluetooth or the cable (on an iPad, the Smart Keyboard connector too), then press a key.")
            } else {
                KeyboardDiagram(held: model.held, ever: model.everPressed)
                HStack {
                    Text(model.leaveProgress > 0 ? "Leaving\u{2026}" : (model.lastKey.map { "Last key: \($0)" } ?? "Press a key")).font(.footnote).foregroundStyle(model.leaveProgress > 0 ? Theme.accent : Theme.textDim)
                    Spacer()
                    if !model.everPressed.isEmpty { Button("Clear marks") { model.reset() }.font(.footnote) }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private var mouseGroup: some View {
        SettingsGroup(title: "Mouse or trackpad", note: model.mouseName == nil ? "No mouse or trackpad connected." : "\(model.mouseName ?? "Mouse"). Move it, click every button, turn the wheel.") {
            if model.mouseName == nil {
                emptyCard("computermouse", "Connect a mouse or trackpad by Bluetooth or the cable, then move it.")
            } else {
                MouseDiagram(model: model)
            }
        }
    }

    private func emptyCard(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout).foregroundStyle(Theme.textDim)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(GlassFill.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct KeyboardDiagram: View {
    let held: Set<UInt>
    let ever: Set<UInt>

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 3
            let width = min(geo.size.width, 760)
            let unit = (width - gap * 14) / 15
            VStack(spacing: gap) {
                ForEach(Array(KeyboardLayout.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: gap) { ForEach(row) { key in cap(key, unit: unit, gap: gap) } }
                }
                HStack(spacing: gap) { ForEach(KeyboardLayout.arrows) { key in cap(key, unit: unit, gap: gap) } }
                    .padding(.top, 4)
            }
            .frame(width: width).frame(maxWidth: .infinity)
        }
        .frame(height: 7 * 30 + 6 * 3 + 4 + 8)
        .padding(10)
        .background(GlassFill.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func cap(_ key: KeySpec, unit: CGFloat, gap: CGFloat) -> some View {
        let code = UInt(key.code.rawValue)
        let isHeld = held.contains(code), was = ever.contains(code)
        return Text(key.label)
            .font(.system(size: min(13, max(8, unit * 0.5)), weight: .semibold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
            .foregroundStyle(isHeld ? Theme.onAccent : Theme.text)
            .frame(width: unit * key.width + gap * (key.width - 1), height: 30)
            .background(isHeld ? Theme.accent : Theme.panelHigh, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(was ? Theme.accent : Theme.line, lineWidth: was ? 1.5 : 0.5))
            .accessibilityLabel(key.label)
            .accessibilityValue(isHeld ? "pressed" : "not pressed")
    }
}

struct MouseDiagram: View {
    @ObservedObject var model: KeyboardMouseTestModel

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panelHigh.opacity(0.6))
                RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1)
                GeometryReader { geo in
                    let w = geo.size.width / 2 - 14, h = geo.size.height / 2 - 14
                    ZStack {
                        Path { p in
                            p.move(to: CGPoint(x: geo.size.width / 2, y: 8)); p.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height - 8))
                            p.move(to: CGPoint(x: 8, y: geo.size.height / 2)); p.addLine(to: CGPoint(x: geo.size.width - 8, y: geo.size.height / 2))
                        }
                        .stroke(Theme.line, lineWidth: 1)
                        ForEach(Array(model.trail.enumerated()), id: \.offset) { i, p in
                            Circle().fill(Theme.accent.opacity(Double(i) / Double(max(model.trail.count, 1)) * 0.5)).frame(width: 6, height: 6)
                                .position(x: geo.size.width / 2 + p.x * w, y: geo.size.height / 2 - p.y * h)
                        }
                        Circle().fill(model.buttons.isEmpty ? Theme.text : Theme.accent).frame(width: 14, height: 14)
                            .position(x: geo.size.width / 2 + model.position.x * w, y: geo.size.height / 2 - model.position.y * h)
                    }
                }
                VStack {
                    Spacer()
                    Text("Move the mouse. The dot follows it.").font(.caption).foregroundStyle(Theme.textDim).padding(.bottom, 6)
                }
            }
            .frame(height: 170)
            HStack(spacing: 8) {
                ForEach(["Left", "Middle", "Right", "Back", "Forward"], id: \.self) { name in
                    Text(name).font(.caption.weight(.semibold)).minimumScaleFactor(0.7).lineLimit(1)
                        .foregroundStyle(model.buttons.contains(name) ? Theme.onAccent : Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(model.buttons.contains(name) ? Theme.accent : Theme.panelHigh, in: Capsule())
                        .overlay(Capsule().stroke(model.everButtons.contains(name) ? Theme.accent : Theme.line, lineWidth: model.everButtons.contains(name) ? 2 : 1))
                        .accessibilityValue(model.buttons.contains(name) ? "pressed" : "not pressed")
                }
            }
            HStack {
                Label(model.wheelFlash > 0 ? "Wheel up" : model.wheelFlash < 0 ? "Wheel down" : "Wheel", systemImage: model.wheelFlash > 0 ? "arrow.up.circle.fill" : model.wheelFlash < 0 ? "arrow.down.circle.fill" : "circle.dotted")
                    .font(.footnote.weight(.semibold)).foregroundStyle(model.wheelFlash == 0 ? Theme.textDim : Theme.accent)
                Spacer()
                Text(String(format: "Moved %.0f, %.0f", model.moved.width, model.moved.height)).font(.footnote.monospacedDigit()).foregroundStyle(Theme.textDim)
                Button("Clear") { model.reset() }.font(.footnote)
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .background(GlassFill.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
