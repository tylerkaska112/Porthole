// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import UIKit

/// The controls sandbox: the same on-screen controls a game draws (CustomControlsView) over a sample screen, with the same editor, so a layout can be tried (every button
/// presses, the sticks move, the haptics tick) and changed before any game is started. What is pressed goes to a readout, never to a game (ControlOutput).
/// The on-screen game controller as the sandbox shows it: the style, layout, size and opacity chosen in Settings.
struct SandboxPad: Equatable {
    var style: VirtualPadStyle, preset: VirtualPadLayout.Preset, scale: Double, alpha: Double

    /// What the person has chosen (the same settings a game starts with).
    static var current: SandboxPad {
        let d = UserDefaults.standard
        return SandboxPad(style: VirtualPadStyle.style(game: nil, last: d.string(forKey: VirtualPadStyle.lastKey)),
                          preset: VirtualPadLayout.preset(game: nil, last: d.string(forKey: VirtualPadLayout.lastKey)),
                          scale: d.object(forKey: VirtualPadDefaults.scaleKey) as? Double ?? 1, alpha: d.object(forKey: VirtualPadDefaults.alphaKey) as? Double ?? 0.55)
    }
}

final class ControlsSandboxView: UIView {
    let controls = CustomControlsView()
    private let padView = VirtualPadView()
    private lazy var editor = ControlsEditorView(controls: controls)
    private let readout = UILabel(), readoutBox = UIView()
    private let reticle = CAShapeLayer(), lookHint = UILabel()
    private let backdrop = CAGradientLayer(), grid = CAShapeLayer()
    private var held: [String] = []
    private var padText = ""
    private var flashTimer: Timer?
    private var flash: String?
    private var lookOffset = CGPoint.zero

    /// Called after every edit with the layout as it now is.
    var onLayoutChanged: ((TouchLayout) -> Void)? { didSet { controls.onChange = onLayoutChanged } }
    /// The editor's Done was tapped.
    var onEditingEnded: (() -> Void)?
    private(set) var isEditing = false

    private var idleText: String

    init(layout: TouchLayout, title: String = "", pad: SandboxPad? = nil) {
        idleText = title.isEmpty ? "Press a control" : "\(title): press a control"
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.11, alpha: 1)
        backdrop.colors = [UIColor(red: 0.10, green: 0.19, blue: 0.27, alpha: 1).cgColor, UIColor(red: 0.04, green: 0.07, blue: 0.11, alpha: 1).cgColor]
        backdrop.startPoint = CGPoint(x: 0, y: 0); backdrop.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(backdrop)
        grid.strokeColor = UIColor(white: 1, alpha: 0.05).cgColor; grid.lineWidth = 1; grid.fillColor = UIColor.clear.cgColor
        layer.addSublayer(grid)
        reticle.strokeColor = UIColor(white: 1, alpha: 0.55).cgColor; reticle.fillColor = UIColor.clear.cgColor; reticle.lineWidth = 2
        layer.addSublayer(reticle)

        lookHint.text = "Drag here to look around"
        lookHint.font = .systemFont(ofSize: 12, weight: .semibold); lookHint.textColor = UIColor(white: 1, alpha: 0.35)
        lookHint.textAlignment = .center
        addSubview(lookHint)

        controls.drawsPictureOutline = true          // the sandbox has no game: the outline shows where the picture would be, so the controls can be planned around it
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([controls.leadingAnchor.constraint(equalTo: leadingAnchor), controls.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     controls.topAnchor.constraint(equalTo: topAnchor), controls.bottomAnchor.constraint(equalTo: bottomAnchor)])
        controls.floatingSticks = FloatingStick.enabled
        padView.translatesAutoresizingMaskIntoConstraints = false
        padView.isHidden = pad == nil
        addSubview(padView)
        NSLayoutConstraint.activate([padView.leadingAnchor.constraint(equalTo: leadingAnchor), padView.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     padView.topAnchor.constraint(equalTo: topAnchor), padView.bottomAnchor.constraint(equalTo: bottomAnchor)])
        padView.floating = FloatingStick.enabled
        padView.onChange = { [weak self] sample in self?.padChanged(sample) }
        if let pad {
            padView.style = pad.style; padView.preset = pad.preset; padView.scale = CGFloat(pad.scale); padView.restingAlpha = CGFloat(pad.alpha)
            controls.isHidden = true
        }
        controls.onPad = { [weak self] sample in self?.padChanged(sample) }
        controls.lookProvider = { [weak self] in self?.controls.layout?.look ?? false }
        controls.apply(layout)

        readoutBox.backgroundColor = UIColor(white: 0, alpha: 0.5)
        readoutBox.layer.cornerRadius = 15; readoutBox.layer.cornerCurve = .continuous
        readoutBox.isUserInteractionEnabled = false
        readout.font = .monospacedSystemFont(ofSize: 13, weight: .semibold); readout.textColor = UIColor(white: 1, alpha: 0.7)
        readout.textAlignment = .center; readout.text = idleText
        readout.translatesAutoresizingMaskIntoConstraints = false; readoutBox.translatesAutoresizingMaskIntoConstraints = false
        readoutBox.addSubview(readout); addSubview(readoutBox)
        NSLayoutConstraint.activate([
            readout.topAnchor.constraint(equalTo: readoutBox.topAnchor, constant: 7), readout.bottomAnchor.constraint(equalTo: readoutBox.bottomAnchor, constant: -7),
            readout.leadingAnchor.constraint(equalTo: readoutBox.leadingAnchor, constant: 14), readout.trailingAnchor.constraint(equalTo: readoutBox.trailingAnchor, constant: -14),
            // In the free middle of the screen: the corners and edges belong to the controls.
            readoutBox.centerXAnchor.constraint(equalTo: centerXAnchor), NSLayoutConstraint(item: readoutBox, attribute: .centerY, relatedBy: .equal, toItem: self, attribute: .bottom, multiplier: 0.3, constant: 0),
            readoutBox.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.42),
        ])

        editor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editor)
        NSLayoutConstraint.activate([editor.leadingAnchor.constraint(equalTo: leadingAnchor), editor.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     editor.topAnchor.constraint(equalTo: topAnchor), editor.bottomAnchor.constraint(equalTo: bottomAnchor)])
        editor.onDone = { [weak self] in self?.setEditing(false); self?.onEditingEnded?() }

        // Dragging the free part of the screen looks around, for a layout that looks.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.cancelsTouchesInView = false
        addGestureRecognizer(pan)
        updateLookHint()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { if ControlOutput.sandbox != nil { ControlOutput.sandbox = nil } }

    // MARK: What a game would receive

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            ControlOutput.sandbox = { [weak self] name, down in self?.report(name, down) }
        } else {
            ControlOutput.sandbox = nil
        }
    }

    private func report(_ name: String, _ down: Bool) {
        // A wheel notch is a click, not a hold: it shows for a moment.
        if name.hasPrefix("Wheel") {
            guard down else { return }
            flash = name
            flashTimer?.invalidate()
            flashTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.flash = nil; self?.refreshReadout() }
            refreshReadout(); return
        }
        if down { if !held.contains(name) { held.append(name) } } else { held.removeAll { $0 == name } }
        refreshReadout()
    }

    private func padChanged(_ s: VirtualPadSample) {
        var parts: [String] = []
        let names: [(VirtualPadButton, String)] = [(.a, "A"), (.b, "B"), (.x, "X"), (.y, "Y"), (.leftBumper, "LB"), (.rightBumper, "RB"), (.up, "Up"), (.down, "Down"), (.left, "Left"), (.right, "Right"), (.start, "Menu"), (.back, "View"), (.leftStick, "L3"), (.rightStick, "R3")]
        for (b, n) in names where s.buttons & b.rawValue != 0 { parts.append(n) }
        if s.leftTrigger > 20 { parts.append(String(format: "LT %.0f%%", Double(s.leftTrigger) / 2.55)) }
        if s.rightTrigger > 20 { parts.append(String(format: "RT %.0f%%", Double(s.rightTrigger) / 2.55)) }
        func stick(_ x: Int16, _ y: Int16, _ name: String) {
            let fx = Double(x) / 32767, fy = Double(y) / 32767
            if hypot(fx, fy) > 0.08 { parts.append(String(format: "%@ stick %.2f, %.2f", name, fx, fy)) }
        }
        stick(s.lx, s.ly, "Left"); stick(s.rx, s.ry, "Right")
        padText = parts.joined(separator: "  \u{00B7}  ")
        refreshReadout()
    }

    private func refreshReadout() {
        var parts: [String] = []
        if !held.isEmpty { parts.append(held.joined(separator: " + ")) }
        if let flash { parts.append(flash) }
        if !padText.isEmpty { parts.append(padText) }
        let text = parts.joined(separator: "   |   ")
        readout.text = text.isEmpty ? idleText : text
        readout.textColor = text.isEmpty ? UIColor(white: 1, alpha: 0.6) : .white
        readoutBox.backgroundColor = text.isEmpty ? UIColor(white: 0, alpha: 0.5) : UIColor(red: 0.12, green: 0.4, blue: 0.62, alpha: 0.85)
    }

    // MARK: The layout

    func apply(_ layout: TouchLayout) {
        held.removeAll(); padText = ""; refreshReadout()
        controls.apply(layout)
        updateLookHint()
    }

    func setEditing(_ on: Bool) {
        guard on != isEditing else { return }
        isEditing = on
        editor.setActive(on)
        readoutBox.isHidden = on
        lookHint.isHidden = on || controls.layout?.look != true
    }

    // MARK: Looking around

    private func updateLookHint() { lookHint.isHidden = isEditing || controls.layout?.look != true; setNeedsLayout() }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard controls.layout?.look == true, !isEditing else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        lookOffset = CGPoint(x: max(-bounds.width * 0.4, min(bounds.width * 0.4, lookOffset.x + t.x)), y: max(-bounds.height * 0.35, min(bounds.height * 0.35, lookOffset.y + t.y)))
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backdrop.frame = bounds; grid.frame = bounds
        let path = UIBezierPath()
        let step: CGFloat = 48
        var x: CGFloat = 0
        while x < bounds.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: bounds.height)); x += step }
        var y: CGFloat = 0
        while y < bounds.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: bounds.width, y: y)); y += step }
        grid.path = path.cgPath
        let c = CGPoint(x: bounds.midX + lookOffset.x, y: bounds.midY + lookOffset.y)
        let r = UIBezierPath(arcCenter: c, radius: 9, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        for d in [CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1)] {
            r.move(to: CGPoint(x: c.x + d.x * 14, y: c.y + d.y * 14))
            r.addLine(to: CGPoint(x: c.x + d.x * 22, y: c.y + d.y * 22))
        }
        reticle.path = r.cgPath
        CATransaction.commit()
        lookHint.frame = CGRect(x: 0, y: bounds.midY + 40, width: bounds.width, height: 18)
    }
}

/// The sandbox in SwiftUI.
struct ControlsSandboxRepresentable: UIViewRepresentable {
    let layout: TouchLayout
    var title = ""
    var pad: SandboxPad?
    @Binding var editing: Bool
    var onChange: (TouchLayout) -> Void

    func makeUIView(context: Context) -> ControlsSandboxView {
        let v = ControlsSandboxView(layout: layout, title: title, pad: pad)
        v.onLayoutChanged = onChange
        v.onEditingEnded = { editing = false }
        return v
    }
    func updateUIView(_ v: ControlsSandboxView, context: Context) {
        v.onLayoutChanged = onChange
        v.onEditingEnded = { editing = false }
        v.setEditing(editing)
    }
}

/// Try a layout (and change it) before a game starts: a full screen over Settings. A phone has to be held sideways, which is how games are played.
struct ControlsSandboxScreen: View {
    let layout: TouchLayout
    let title: String
    /// Set to try the on-screen game controller instead of a layout.
    var pad: SandboxPad?
    var startEditing = false
    var onChange: (TouchLayout) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var started = false

    var body: some View {
        GeometryReader { geo in
            let upright = geo.size.height > geo.size.width
            ZStack {
                ControlsSandboxRepresentable(layout: layout, title: title, pad: pad, editing: $editing, onChange: onChange).ignoresSafeArea()
                if upright {
                    VStack(spacing: 14) {
                        Image(systemName: "iphone.landscape").font(.system(size: 44, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text("Turn your device sideways").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        Text("Games are played that way, so the controls are tried that way too.").font(.system(size: 14, design: .rounded)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                        PillButton(id: "cs-close-upright", title: "Close", symbol: "xmark") { dismiss() }
                    }
                    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.82).ignoresSafeArea())
                } else if !editing {
                    // Two small buttons in the corners, clear of the controls that sit along the top.
                    VStack {
                        // The on-screen controller has controls in the top corners, so its Close button goes to the middle of the left edge.
                        if pad != nil { Spacer() }
                        HStack {
                            Button { dismiss() } label: {
                                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white).frame(width: 40, height: 40).background(.black.opacity(0.55), in: Circle())
                            }.buttonStyle(.plain).accessibilityLabel("Close")
                            Spacer()
                            if pad == nil { Button { editing = true } label: {
                                Image(systemName: "pencil").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.onAccent).frame(width: 40, height: 40)
                                    .background(Theme.accentGradient, in: Circle())
                            }.buttonStyle(.plain).accessibilityLabel("Edit the layout") }
                        }
                        .padding(.horizontal, 8).padding(.top, pad == nil ? 6 : 0)
                        Spacer()
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .onAppear { if startEditing, !started { started = true; editing = true } }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }
}
