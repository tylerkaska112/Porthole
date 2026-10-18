// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// Settings-style rows. Every one is a focus target: the D-pad moves between them, A presses, and Left / Right changes a slider or a choice without leaving the row.

/// A titled stack of rows.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Theme.label(title).padding(.horizontal, 6) }
            VStack(spacing: 8) { content }
        }
    }
}

/// A page: a big title, then groups.
/// Set by a page that shows other pages inside itself: their own big title and padding are dropped, and their groups follow one another under the host's title.
private struct EmbeddedPageKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var embeddedPage: Bool { get { self[EmbeddedPageKey.self] } set { self[EmbeddedPageKey.self] = newValue } } }

struct PageScaffold<Content: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var content: Content
    @Environment(\.embeddedPage) private var embedded
    var body: some View {
        if embedded {
            VStack(alignment: .leading, spacing: 22) { content }.frame(maxWidth: .infinity, alignment: .leading)
        } else { framed }
    }
    private var framed: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                if let symbol { Image(systemName: symbol).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.accentGradient) }
                Text(title).font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
}

/// The frame every row shares: icon, title, a short second line, an optional (i), and whatever sits on the right.
struct RowBase<Trailing: View>: View {
    let id: AnyHashable
    var symbol: String?
    var tint: Color = Theme.accent
    let title: String
    var subtitle: String?
    var info: String?
    var destructive = false
    var adjust: ((Int) -> Void)?
    /// A label, not a button: no card, so it can't be mistaken for something to press.
    var plain = false
    /// The one thing to do on a page: filled with the accent so it reads as a button.
    var emphasized = false
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                if let symbol { IconTile(symbol: symbol, tint: destructive ? Theme.bad : tint, size: 32) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: emphasized ? .bold : .semibold, design: .rounded)).foregroundStyle(destructive ? Theme.bad : emphasized ? Theme.accent : plain ? Theme.text.opacity(0.85) : Theme.text).lineLimit(2)
                    if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(2) }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.leading, 14).padding(.trailing, info == nil ? 14 : 4).padding(.vertical, 10)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            if let info { InfoButton(id: "\(id)-info", title: title, text: info) }
        }
        .background(plain ? AnyShapeStyle(Color.clear) : emphasized ? AnyShapeStyle(Theme.accent.opacity(0.16)) : AnyShapeStyle(Theme.panel), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(plain ? Color.clear : emphasized ? Theme.accent.opacity(0.7) : Theme.line, lineWidth: emphasized ? 1.5 : 1))
        .focusTarget(id, radius: 16, scale: 1.012, adjust: adjust, action: action)
    }
}

/// A switch.
struct ToggleRow: View {
    let id: AnyHashable
    var symbol: String?
    var tint: Color = Theme.accent
    let title: String
    var subtitle: String?
    var info: String?
    @Binding var isOn: Bool

    var body: some View {
        RowBase(id: id, symbol: symbol, tint: tint, title: title, subtitle: subtitle, info: info, adjust: { isOn = $0 > 0 }, action: { isOn.toggle() }) {
            GlowSwitch(isOn: isOn)
        }
    }
}

struct GlowSwitch: View {
    let isOn: Bool
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh)).frame(width: 52, height: 30)
                .shadow(color: isOn ? Theme.accent.opacity(0.5 * Theme.glowStrength) : .clear, radius: 8)
            Circle().fill(.white).frame(width: 24, height: 24).padding(3).shadow(radius: 2, y: 1)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
        .accessibilityHidden(true)
    }
}

/// Pick one of several. A opens a list; Left / Right steps through the choices.
struct ChoiceRow<T: Hashable>: View {
    let id: AnyHashable
    var symbol: String?
    var tint: Color = Theme.accent
    let title: String
    var subtitle: String?
    var info: String?
    let options: [(T, String)]
    @Binding var selection: T
    @State private var open = false
    @State private var sheetScope = FocusScope()

    private var label: String { options.first { $0.0 == selection }?.1 ?? "\u{2014}" }

    var body: some View {
        RowBase(id: id, symbol: symbol, tint: tint, title: title, subtitle: subtitle, info: info, adjust: step, action: { open = true }) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Theme.textDim)
            }
        }
        .sheet(isPresented: $open) {
            ChoiceSheet(title: title, options: options, selected: selection, scope: sheetScope) { value in
                if let value { selection = value }
                open = false
            }
        }
    }

    private func step(_ direction: Int) {
        guard let i = options.firstIndex(where: { $0.0 == selection }) else { return }
        let next = min(max(i + direction, 0), options.count - 1)
        if next != i { selection = options[next].0 }
    }
}

/// The list a choice opens: one target per option, the current one focused first.
struct ChoiceSheet<T: Hashable>: View {
    let title: String
    let options: [(T, String)]
    let selected: T
    let scope: FocusScope
    let done: (T?) -> Void

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "choice-cancel", title: "Cancel", symbol: "xmark") { done(nil) }
                }
                FocusScroll {
                    VStack(spacing: 8) {
                        ForEach(options.indices, id: \.self) { i in
                            let option = options[i]
                            Button { done(option.0) } label: {
                                HStack {
                                    Text(option.1).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                                    Spacer()
                                    if option.0 == selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                                }
                                .padding(.horizontal, 16).frame(minHeight: 54)
                                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(option.0 == selected ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .focusTarget("choice-\(i)", radius: 16, scale: 1.015) { done(option.0) }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 20)
        }
        .navScope(scope)
        .onAppear {
            scope.onBack = { done(nil) }
            if let i = options.firstIndex(where: { $0.0 == selected }) { scope.defaultFocus = "choice-\(i)"; scope.focused = "choice-\(i)" }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
    }
}

/// A value on a track. Drag it, or press Left / Right.
struct SliderRow: View {
    let id: AnyHashable
    var symbol: String?
    let title: String
    var info: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    var format: (Double) -> String = { String(format: "%.1f", $0) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let symbol { IconTile(symbol: symbol, tint: Theme.accent, size: 32) }
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                Spacer()
                Text(format(value)).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent).monospacedDigit()
                if let info { InfoButton(id: "\(id)-info", title: title, text: info) }
            }
            GeometryReader { geo in
                let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panelHigh).frame(height: 8)
                    Capsule().fill(Theme.accentGradient).frame(width: max(8, geo.size.width * fraction), height: 8)
                    Circle().fill(.white).frame(width: 22, height: 22).shadow(color: Theme.accent.opacity(0.7 * Theme.glowStrength), radius: 8)
                        .offset(x: max(0, min(geo.size.width - 22, geo.size.width * fraction - 11)))
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = min(max(g.location.x / geo.size.width, 0), 1)
                    set(range.lowerBound + f * (range.upperBound - range.lowerBound))
                })
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .focusTarget(id, radius: 16, scale: 1.012, adjust: { set(value + Double($0) * step) }, action: {})
    }

    private func set(_ new: Double) {
        let snapped = (new / step).rounded() * step
        value = min(max(snapped, range.lowerBound), range.upperBound)
    }
}

/// A button-like row: an action, with a symbol and optional detail on the right.
struct ActionRow: View {
    let id: AnyHashable
    var symbol: String?
    var tint: Color = Theme.accent
    let title: String
    var subtitle: String?
    var detail: String?
    /// A small label next to the title's end, such as "Beta", for a feature that is not finished or fully tested.
    var badge: String?
    var info: String?
    var destructive = false
    var chevron = true
    /// The main button of a page (filled with the accent), as opposed to a quieter row.
    var prominent = false
    let action: () -> Void

    var body: some View {
        RowBase(id: id, symbol: symbol, tint: tint, title: title, subtitle: subtitle, info: info, destructive: destructive, emphasized: prominent, action: action) {
            HStack(spacing: 8) {
                if let badge { BetaBadge(text: badge) }
                if let detail { Text(detail).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1) }
                if prominent { Image(systemName: "arrow.right.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.accent) }
                else if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.textDim) }
            }
        }
    }
}

/// A small capsule that marks something as beta: new, mostly untested.
struct BetaBadge: View {
    var text = "Beta"
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(0.8)
            .foregroundStyle(Theme.warn)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.warn.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Theme.warn.opacity(0.5), lineWidth: 1))
            .accessibilityLabel(text)
    }
}

/// A label and a value (not pressable, but reachable so a page of them can be scrolled with the D-pad).
struct ValueRow: View {
    let id: AnyHashable
    var symbol: String?
    let title: String
    let value: String
    var statusColor: Color?
    var action: () -> Void = {}
    var body: some View {
        RowBase(id: id, symbol: symbol, title: title, plain: true, action: action) {
            HStack(spacing: 6) {
                if let statusColor { Circle().fill(statusColor).frame(width: 8, height: 8).shadow(color: statusColor.opacity(0.8), radius: 3) }
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textDim).multilineTextAlignment(.trailing).lineLimit(2)
            }
        }
    }
}

/// A row for a sidebar or a list of pages: a button with the page's icon and name, a card of its own, lit when it is the page being shown.
struct SidebarRow: View {
    let id: AnyHashable
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    var selected: Bool
    var onFocus: (() -> Void)?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, tint: tint, size: 34)
                Text(title).font(.system(size: 17, weight: selected ? .bold : .semibold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                if let detail { Text(detail).font(.caption.weight(.bold)).foregroundStyle(Theme.onAccent).padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent, in: Capsule()) }
                if !selected { Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.textDim) }
            }
            .padding(.horizontal, 14).frame(minHeight: 58)
            .background(selected ? Theme.panelHigh : Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: selected ? 1.5 : 1))
            // A plain button only answers where something is drawn; the whole card is pressable.
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusTarget(id, radius: 16, scale: 1.02, onFocus: onFocus, action: action)
    }
}


/// A page made of several smaller ones, one after another.
struct CombinedPage<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        PageScaffold(title: title, symbol: symbol) { content.environment(\.embeddedPage, true) }
    }
}
