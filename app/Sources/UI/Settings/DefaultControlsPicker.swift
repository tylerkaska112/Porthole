// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Settings > Controls > Default controls: how every game is controlled until it has controls of its own. One card for each choice, with a small picture of where its buttons sit.
/// What is chosen here is what a game with no controls of its own starts with (DefaultControls); whether a game works with it is found out by playing.
struct DefaultControlsPicker: View {
    @State private var choice = DefaultControls.current
    @State private var sandbox: SandboxRequest?
    /// The on-screen controller's own choices (kept where a game reads them): its style, layout, size and opacity.
    @State private var pad = SandboxPad.current
    /// iPad only: the game's picture goes to the top edge while on-screen controls are in use (PictureBand).
    @AppStorage(PictureBand.settingKey) private var pictureUp = true
    private struct SandboxRequest: Identifiable { let id = UUID(); let edit: Bool }
    private let columns = [GridItem(.adaptive(minimum: 158), spacing: 12, alignment: .top)]

    var body: some View {
        SettingsGroup(title: "Default controls", note: "Every game starts with this, unless you set up controls for that game.") {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(DefaultControls.Kind.allCases) { kind in card(kind) }
            }
            if choice.kind == .onScreenPad {
                padOptions
                PillButton(id: "dc-try", title: "Try it", symbol: "hand.tap.fill", style: .primary) { sandbox = SandboxRequest(edit: false) }
                Text("Press the controller and feel it. Nothing here reaches a game.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            } else if layout(for: choice.kind) != nil {
                HStack(spacing: 10) {
                    PillButton(id: "dc-try", title: "Try it", symbol: "hand.tap.fill", style: .primary) { sandbox = SandboxRequest(edit: false) }
                    PillButton(id: "dc-edit", title: "Edit", symbol: "pencil") { sandbox = SandboxRequest(edit: true) }
                }
                Text("Press the buttons and feel the layout, or move and resize them. Nothing here reaches a game.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
            if UIDevice.current.userInterfaceIdiom == .pad, [.onScreenPad, .gamepad, .custom].contains(choice.kind) {
                ToggleRow(id: "dc-picture-up", symbol: "rectangle.tophalf.inset.filled", title: "Picture above the controls",
                          info: "While these on-screen controls are in use, the game's picture moves to the top edge of the iPad and the controls sit under it, covering as little of the game as possible. The picture is never cropped or made smaller. It does not move when you play with a mouse and keyboard or a real controller, or when there is too little room under the picture.",
                          isOn: $pictureUp)
            }
        }
        .fullScreenCover(item: $sandbox, onDismiss: { choice = DefaultControls.current }) { request in
            if choice.kind == .onScreenPad {
                ControlsSandboxScreen(layout: TouchLayout(), title: "On-screen controller", pad: pad) { _ in }
            } else if let layout = layout(for: choice.kind) {
                ControlsSandboxScreen(layout: layout, title: choice.kind.title, startEditing: request.edit) { edited in
                    // The first change makes the layout the person's own: it is kept as My own layout and is the default.
                    var d = DefaultControls.current
                    d.use(custom: edited)
                    DefaultControls.current = d
                }
            }
        }
    }

    /// How the on-screen controller is set up: the controller it imitates, its size and how solid it is.
    @ViewBuilder private var padOptions: some View {
        ChoiceRow(id: "dc-pad-layout", symbol: "square.grid.3x2.fill", title: "Layout",
                  info: VirtualPadLayout.Preset.allCases.map { "\($0.title): \($0.detail)" }.joined(separator: "\n\n") + "\n\nEvery controller type has both.",
                  options: VirtualPadLayout.Preset.allCases.map { ($0, $0.title) },
                  selection: Binding(get: { pad.preset }, set: { p in
                      pad.preset = p
                      UserDefaults.standard.set(p.rawValue, forKey: VirtualPadLayout.lastKey)
                  }))
        ChoiceRow(id: "dc-pad-style", symbol: "gamecontroller.fill", title: "Controller type",
                  info: VirtualPadStyle.allCases.map { "\($0.title): \($0.detail)" }.joined(separator: "\n\n") + "\n\nA type changes only the names and colours on the buttons. The game always sees an Xbox pad.",
                  options: VirtualPadStyle.allCases.map { ($0, $0.title) },
                  selection: Binding(get: { pad.style }, set: { st in
                      pad.style = st
                      UserDefaults.standard.set(st.rawValue, forKey: VirtualPadStyle.lastKey)
                  }))
        SliderRow(id: "dc-pad-size", symbol: "arrow.up.left.and.arrow.down.right", title: "Size",
                  value: Binding(get: { pad.scale }, set: { pad.scale = $0; UserDefaults.standard.set($0, forKey: VirtualPadDefaults.scaleKey) }), range: 0.6...1.4, step: 0.1,
                  format: { "\(Int(($0 * 100).rounded()))%" })
        SliderRow(id: "dc-pad-opacity", symbol: "circle.lefthalf.filled", title: "Opacity",
                  value: Binding(get: { pad.alpha }, set: { pad.alpha = $0; UserDefaults.standard.set($0, forKey: VirtualPadDefaults.alphaKey) }), range: 0.2...1.0, step: 0.05,
                  format: { "\(Int(($0 * 100).rounded()))%" })
    }

    private func layout(for kind: DefaultControls.Kind) -> TouchLayout? {
        switch kind {
        case .universal: ShippedLayouts.universal.layout
        case .onScreenPad: TouchLayout.gamepad          // only for the small picture; the controller itself is drawn by VirtualPadView
        case .gamepad: TouchLayout.gamepad
        case .custom: choice.custom
        }
    }

    private func card(_ kind: DefaultControls.Kind) -> some View {
        let available = kind != .custom || choice.custom != nil
        let selected = choice.kind == kind
        return Button { select(kind) } label: {
            VStack(alignment: .leading, spacing: 8) {
                LayoutPreview(layout: layout(for: kind), caption: kind == .onScreenPad ? pad.style.title : nil)
                    .overlay(alignment: .topTrailing) {
                        if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.accent, Theme.onAccent).padding(6) }
                    }
                Text(kind.title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
                Text(kind.detail)
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(Theme.accent.opacity(0.14)) : AnyShapeStyle(GlassFill.panel), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? Theme.accent.opacity(0.8) : Theme.line, lineWidth: selected ? 2 : 1))
            .opacity(available ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusTarget("dc-\(kind.rawValue)", radius: 16, scale: 1.02) { select(kind) }
        .accessibilityLabel(kind.title)
        .accessibilityHint(available ? kind.detail : "Nothing saved yet")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ kind: DefaultControls.Kind) {
        guard kind != .custom || choice.custom != nil else { return }
        choice.kind = kind
        DefaultControls.current = choice
    }
}

/// A small picture of a game screen with the controls of a layout where they sit: round for sticks and the D-pad, rounded for buttons.
struct LayoutPreview: View {
    let layout: TouchLayout?
    /// A small tag in the picture's corner (the controller type of the on-screen controller).
    var caption: String?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // A layout is placed for a phone held sideways (about 850 points wide): the picture scales its control sizes down to its own width.
            let scale = w / 850
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.55))
                if layout?.look == true {
                    // Looking around: the free half of the screen drags the view.
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: w * 0.4, height: h * 0.55).position(x: w * 0.62, y: h * 0.4)
                }
                if let layout {
                    ForEach(layout.controls) { c in
                        let round = c.action.hasPrefix("stick") || c.action.hasPrefix("dpad")
                        let d = max(8, CGFloat(c.size) * scale)
                        ZStack {
                            if round { Circle().fill(Theme.accent.opacity(0.3)).overlay(Circle().strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1)) }
                            else { RoundedRectangle(cornerRadius: d * 0.3, style: .continuous).fill(.white.opacity(0.22)).overlay(RoundedRectangle(cornerRadius: d * 0.3, style: .continuous).strokeBorder(.white.opacity(0.55), lineWidth: 1)) }
                            if d >= 14, !c.label.isEmpty { Text(c.label).font(.system(size: min(d * 0.42, 11), weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.9)).minimumScaleFactor(0.5).lineLimit(1) }
                        }
                        .frame(width: d, height: d)
                        .position(x: w * CGFloat(c.x), y: h * CGFloat(c.y))
                    }
                } else {
                    Image(systemName: "questionmark").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textDim)
                }
                if let caption {
                    Text(caption).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.55), in: Capsule())
                        .position(x: w / 2, y: h * 0.5)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
