// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The pieces the in-game menu is built from, with no dependency on the app, so the UI preview app can draw them.
//
// The menu is a short list of ROWS per tab (an icon, a name and the value it has now), and a row that has options opens a PAGE of its own with a Back button, the way iOS
// Settings does. That keeps every screen short: a phone held sideways has room for about five rows, and the old menu put every option of every setting in one long scroll.

// MARK: - The page being shown

private struct MenuPageTitleKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    /// The title of the page the menu is showing, so a card inside it does not print the same words again as its own label.
    var menuPageTitle: String {
        get { self[MenuPageTitleKey.self] }
        set { self[MenuPageTitleKey.self] = newValue }
    }
}

private struct MenuRegularKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The menu is drawn roomy: an iPad's card. Rows get larger type and touch targets (a thumb has a whole tablet to reach across).
    var menuRegular: Bool {
        get { self[MenuRegularKey.self] }
        set { self[MenuRegularKey.self] = newValue }
    }
}

// MARK: - Cards and rows

/// A group of rows with a small label above it and an optional note below.
struct MenuCard<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content
    @Environment(\.menuPageTitle) private var pageTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty && title.caseInsensitiveCompare(pageTitle) != .orderedSame { Theme.label(title).padding(.leading, 4) }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            if let footer, !footer.isEmpty {
                Text(footer).font(.system(size: 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

/// One choice out of several: its name, a line about it, and a check on the one that is on.
struct MenuChoiceRow: View {
    let title: String
    var detail: String?
    let selected: Bool
    let action: () -> Void
    @Environment(\.menuRegular) private var regular
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: regular ? 17 : 15, weight: .semibold)).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.system(size: regular ? 13.5 : 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: regular ? 22 : 19)).foregroundStyle(selected ? Theme.accent : Theme.textDim.opacity(0.6))
            }
            .padding(.horizontal, regular ? 16 : 12).padding(.vertical, regular ? 12 : 10).frame(minHeight: regular ? 58 : 46)
            .background(selected ? Theme.accent.opacity(0.11) : Color.clear)          // the chosen one is easy to find
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusTarget("choice:\(title)", radius: 8, scale: 1.0, action: action)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MenuToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    @Environment(\.menuRegular) private var regular
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: regular ? 17 : 15, weight: .semibold)).foregroundStyle(Theme.text)
                if let detail { Text(detail).font(.system(size: regular ? 13.5 : 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, regular ? 16 : 12).padding(.vertical, regular ? 10 : 8).frame(minHeight: regular ? 58 : 46)
        .focusTarget("toggle:\(title)", radius: 8, scale: 1.0) { isOn.toggle() }
    }
}

struct MenuActionRow: View {
    let title: String
    var symbol: String?
    var detail: String?
    var destructive = false
    /// The controller's focus id when titles repeat (the same channel name on two servers).
    var focusID: String?
    let action: () -> Void
    @Environment(\.menuRegular) private var regular
    var body: some View {
        Button(action: action) {
            HStack(spacing: regular ? 14 : 10) {
                if let symbol { Image(systemName: symbol).font(.system(size: regular ? 19 : 16, weight: .semibold)).frame(width: regular ? 28 : 24).foregroundStyle(destructive ? Theme.bad : Theme.accent) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: regular ? 17 : 15, weight: .semibold)).foregroundStyle(destructive ? Theme.bad : Theme.text)
                    if let detail { Text(detail).font(.system(size: regular ? 13.5 : 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: regular ? 13 : 12, weight: .bold)).foregroundStyle(Theme.textDim.opacity(0.6))
            }
            .padding(.horizontal, regular ? 16 : 12).padding(.vertical, regular ? 12 : 10).frame(minHeight: regular ? 58 : 46).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusTarget(focusID ?? "action:\(title)", radius: 8, scale: 1.0, action: action)
    }
}

/// A row that opens a page of options: a tinted icon, the setting's name, the value it has now and a chevron.
struct MenuNavRow: View {
    let id: String
    let symbol: String
    var tint: Color = Theme.accent
    let title: String
    var value: String?
    let action: () -> Void
    @Environment(\.menuRegular) private var regular
    var body: some View {
        Button(action: action) {
            HStack(spacing: regular ? 14 : 12) {
                Image(systemName: symbol).font(.system(size: regular ? 17 : 14, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: regular ? 38 : 30, height: regular ? 38 : 30).background(tint.opacity(0.17), in: RoundedRectangle(cornerRadius: regular ? 10 : 8, style: .continuous))
                Text(title).font(.system(size: regular ? 17 : 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).layoutPriority(2)
                Spacer(minLength: 6)
                if let value, !value.isEmpty {
                    // The name always shows in full; the value gives way (smaller, then cut).
                    Text(value).font(.system(size: regular ? 15 : 13, weight: .medium)).foregroundStyle(Theme.textDim).lineLimit(1).minimumScaleFactor(0.75).layoutPriority(1)
                }
                Image(systemName: "chevron.right").font(.system(size: regular ? 13 : 12, weight: .bold)).foregroundStyle(Theme.textDim.opacity(0.6))
            }
            .padding(.horizontal, regular ? 16 : 12).padding(.vertical, regular ? 11 : 9).frame(minHeight: regular ? 62 : 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusTarget("nav:\(id)", radius: 8, scale: 1.0, action: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(.isButton)
    }
}

struct MenuDivider: View { var body: some View { Divider().overlay(Theme.line).padding(.leading, 12) } }

/// A row that opens to a few lines of explanation, closed at first: long text under a card pushed the choices off the screen of a phone held sideways.
struct MenuExpandRow: View {
    let title: String
    let text: String
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textDim).rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusTarget("expand:\(title)", radius: 8, scale: 1.0) { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }
}

// MARK: - The panel's frame

struct MenuTabItem: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
}

/// One row of equal tabs. The icon has a box of its own and the label is one line (scaled down a little when five tabs share a narrow panel), so every tab lines up and
/// "Performance" never breaks in the middle of the word.
struct MenuTabBar: View {
    let tabs: [MenuTabItem]
    let selection: String
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let on = selection == tab.id
                Button { select(tab.id) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 15, weight: .semibold)).frame(height: 18)
                        Text(tab.title).font(.system(size: 10.5, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.72).allowsTightening(true)
                    }
                    .foregroundStyle(on ? Theme.onAccent : Theme.textDim)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background { if on { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.accentGradient) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .coachTarget("menu-tab-\(tab.id)")
                .accessibilityAddTraits(on ? .isSelected : [])      // the tabs change with LB and RB or a tap, not with the D-pad
            }
        }
        .padding(3)
        .background(Theme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

/// The tabs as a row of pills with an icon over a short label, the chosen one filled with the accent: an iPad's card, where a row of five has room and each is a big target.
struct MenuPillTabs: View {
    let tabs: [MenuTabItem]
    let selection: String
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let on = selection == tab.id
                Button { select(tab.id) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 19, weight: .semibold)).frame(height: 24)
                        Text(tab.title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7).allowsTightening(true)
                    }
                    .foregroundStyle(on ? Theme.onAccent : Theme.textDim)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background { if on { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accentGradient).shadow(color: Theme.accent.opacity(0.35 * Theme.glowStrength), radius: 8, y: 2) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .coachTarget("menu-tab-\(tab.id)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// How wide the iPad's card may be, and what a drag of its handle does. Pure arithmetic, so it is tested without a screen (Tests/MenuCard).
enum MenuCardSizing {
    static let margin: CGFloat = 14
    /// The handle sticks out to the left of the card; it must stay on screen, so the card never reaches the far edge.
    static let handleRoom: CGFloat = 34
    static let minimum: CGFloat = 380

    /// The size the card has until the person changes it: about 500 points held sideways, up to 560 held upright.
    static func standard(total: CGFloat) -> CGFloat { max(minimum, min(total - 2 * margin - 40, total > 900 ? 500 : 560)) }
    static func maximum(total: CGFloat) -> CGFloat { max(minimum, total - 2 * margin - handleRoom) }
    static func clamp(_ width: CGFloat, total: CGFloat) -> CGFloat { min(max(width, minimum), maximum(total: total)) }
    /// The width a drag proposes: dragging the handle to the left (a negative move) makes the card wider.
    static func dragged(from start: CGFloat, by move: CGFloat) -> CGFloat { start - move }
    /// A drag that pulls the card in well past its smallest size and lets go closes the menu: the handle that opens it also throws it away.
    static func shouldClose(proposed width: CGFloat) -> Bool { width < minimum - 70 }
    /// What the expand button gives: most of the screen.
    static func large(total: CGFloat) -> CGFloat { clamp(total * 0.82, total: total) }
    static func isLarge(_ width: CGFloat, total: CGFloat) -> Bool { width > standard(total: total) + 60 }
}

/// The size the person gave the iPad's card, kept between games. Nil means the standard size for the screen it is on.
@MainActor
final class MenuCardSize: ObservableObject {
    static let shared = MenuCardSize()
    static let key = "f4.menuCardWidth"
    @Published private(set) var custom: CGFloat?

    private init() { let v = UserDefaults.standard.double(forKey: Self.key); custom = v >= MenuCardSizing.minimum ? CGFloat(v) : nil }

    func width(total: CGFloat) -> CGFloat { custom.map { MenuCardSizing.clamp($0, total: total) } ?? MenuCardSizing.standard(total: total) }

    func set(_ width: CGFloat, total: CGFloat) {
        let w = MenuCardSizing.clamp(width, total: total)
        // A size that is the standard one is the standard one: it follows the screen when the iPad is turned.
        if abs(w - MenuCardSizing.standard(total: total)) < 1 { reset(); return }
        custom = w
        UserDefaults.standard.set(Double(w), forKey: Self.key)
    }

    func reset() { custom = nil; UserDefaults.standard.removeObject(forKey: Self.key) }

    func isLarge(total: CGFloat) -> Bool { MenuCardSizing.isLarge(width(total: total), total: total) }

    /// The expand button: large, or back to the standard size.
    func toggleLarge(total: CGFloat) { if isLarge(total: total) { reset() } else { set(MenuCardSizing.large(total: total), total: total) } }
}

/// The iPad's floating card: margins, rounded corners, one solid surface, and a handle on its left edge. A tap on the handle closes the menu; dragging it resizes the card (to the left makes it
/// bigger, to the right smaller, and well past the smallest size closes it): the way the menu came in from the screen's edge is the way it goes out. A swipe to the right anywhere on the card
/// does the same as the Back or Close it is on.
struct MenuCardFrame<Content: View>: View {
    /// The width of the screen the card sits on.
    let total: CGFloat
    let safe: EdgeInsets
    let close: () -> Void
    let swipeBack: () -> Void
    @ViewBuilder var content: Content
    @ObservedObject private var size = MenuCardSize.shared
    /// While the handle is being dragged: the width the card has at this moment (not yet kept).
    @State private var live: CGFloat?
    @State private var dragStart: CGFloat?
    static var margin: CGFloat { MenuCardSizing.margin }

    init(total: CGFloat, safe: EdgeInsets, close: @escaping () -> Void, swipeBack: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.total = total; self.safe = safe; self.close = close; self.swipeBack = swipeBack; self.content = content()
    }

    private var width: CGFloat { live ?? size.width(total: total) }

    var body: some View {
        content
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(MenuCardSurface())
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(alignment: .leading) { handle.offset(x: -22) }
            .padding(.trailing, max(Self.margin, safe.trailing + 6))
            .padding(.top, max(Self.margin, safe.top + 4))
            .padding(.bottom, max(Self.margin, safe.bottom + 4))
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                if v.translation.width > 70, abs(v.translation.height) < v.translation.width * 0.6 { swipeBack() }
            })
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var handle: some View {
        VStack(spacing: 9) {
            Image(systemName: "chevron.right").font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.accent)
            // Two short bars: this edge can be dragged.
            HStack(spacing: 4) { ForEach(0..<2, id: \.self) { _ in Capsule().fill(Theme.textDim.opacity(0.7)).frame(width: 3, height: 26) } }
        }
        .frame(width: 30, height: 104)
        .background(Capsule().fill(Color(red: 0.07, green: 0.10, blue: 0.16)))
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { v in
                    let start = dragStart ?? width
                    dragStart = start
                    // Pulled in past the smallest size, the card keeps that size (and closes on release); otherwise it follows the finger.
                    live = MenuCardSizing.clamp(MenuCardSizing.dragged(from: start, by: v.translation.width), total: total)
                }
                .onEnded { v in
                    let start = dragStart ?? width
                    dragStart = nil
                    let proposed = MenuCardSizing.dragged(from: start, by: v.translation.width)
                    live = nil
                    if MenuCardSizing.shouldClose(proposed: proposed) { close() } else { size.set(proposed, total: total) }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Menu edge")
        .accessibilityHint("Tap to close the menu, or drag to change how wide it is")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { close() }
    }
}

/// An iPad card's surface: one dark glass shape with a soft wash of the accent at the top, nearly opaque. (A see-through panel showed the game's own menu, its on-screen controls and the
/// overlay through every row. The "Background" setting still works, between mostly and fully solid.)
struct MenuCardSurface: View {
    @ObservedObject private var look = MenuAppearance.shared
    var radius: CGFloat = 30

    var body: some View {
        let alpha = 0.82 + 0.18 * look.solidity
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.12, blue: 0.18).opacity(alpha), Color(red: 0.04, green: 0.06, blue: 0.10).opacity(alpha)], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                LinearGradient(colors: [Theme.accent.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom).frame(height: 200).clipShape(shape)
            }
            .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 28, x: -6, y: 8)
    }
}

/// What the menu is drawn on: dark, but see-through enough that the game shows behind it. A plain tint, not a blur: a blur of the whole screen would make the game's picture cost more
/// to draw while the menu is open (the game keeps running behind it).
struct MenuBackdrop: View {
    @ObservedObject private var look = MenuAppearance.shared
    var body: some View {
        LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.1).opacity(look.solidity), Color(red: 0.03, green: 0.04, blue: 0.08).opacity(max(0, look.solidity - 0.1))], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// How solid the menu's background is (Game tab > This menu > Background): lower shows more of the game behind it.
@MainActor
final class MenuAppearance: ObservableObject {
    static let shared = MenuAppearance()
    static let key = "f4.menuSolidity"
    static let range: ClosedRange<Double> = 0.3...1.0
    @Published private(set) var solidity: Double

    private init() { solidity = min(max(UserDefaults.standard.object(forKey: Self.key) as? Double ?? 0.76, Self.range.lowerBound), Self.range.upperBound) }

    /// One step more or less solid (5 percent).
    func step(_ steps: Int) {
        solidity = min(max(((solidity + Double(steps) * 0.05) * 20).rounded() / 20, Self.range.lowerBound), Self.range.upperBound)
        UserDefaults.standard.set(solidity, forKey: Self.key)
    }
}

/// The tabs as a slim column down the left edge: an icon over a one-word label, the picked one filled. It leaves the width for the cards.
struct MenuRail: View {
    let tabs: [MenuTabItem]
    let selection: String
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(tabs) { tab in
                let on = selection == tab.id
                Button { select(tab.id) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 19, weight: .semibold)).frame(height: 22)
                        Text(tab.title).font(.system(size: 10.5, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7).allowsTightening(true)
                    }
                    .foregroundStyle(on ? Theme.onAccent : Theme.textDim)
                    .frame(width: 78, height: 56)
                    .background { if on { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accentGradient) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .coachTarget("menu-tab-\(tab.id)")
                .accessibilityAddTraits(on ? .isSelected : [])      // the tabs change with LB and RB or a tap, not with the D-pad
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12).padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        // Wider than the rail on purpose: on a phone held sideways the rail's colour also fills the strip beside the notch.
        .background(alignment: .trailing) { Theme.panel.opacity(0.55).frame(width: 400).ignoresSafeArea() }
    }
}

/// The menu's frame. Wide (a phone held sideways, an iPad): the tabs down the left, the page's name and Back at the top of the rest, and the cards in ONE column (a controller moves
/// straight up and down through it; two columns made it jump about), no wider than is comfortable to read. Narrow
/// (a phone held upright): a title bar, a row of tabs and one column. While a page is open the narrow layout drops its tabs to give the page the room.
struct MenuChrome<Content: View>: View {
    var title = "Menu"
    var subtitle: String?
    /// The page being shown (nil = the tab's own list).
    var page: String?
    /// What Back says it goes back to (the tab's name).
    var backTitle = ""
    let tabs: [MenuTabItem]
    let tab: String
    let selectTab: (String) -> Void
    let back: () -> Void
    let close: () -> Void
    /// An iPad's floating card: a header with a big Close, the tabs as a row of pills under it, roomy rows. Everything else keeps the phone's layouts.
    var card = false
    /// The card's expand button (nil: none) and whether it is already large.
    var toggleSize: (() -> Void)?
    var sizeIsLarge = false
    @ViewBuilder var content: Content

    /// Width from which the tabs go to the side.
    static var wideFrom: CGFloat { 560 }

    var body: some View {
        GeometryReader { geo in
            if card { cardLayout }
            else if geo.size.width >= Self.wideFrom { wide(width: geo.size.width) } else { narrow }
        }
        .animation(.easeOut(duration: 0.22), value: page)
    }

    // MARK: Card (iPad)

    private var cardLayout: some View {
        // A card the person has made very wide keeps its words in a comfortable column in the middle.
        cardColumn.frame(maxWidth: 760).frame(maxWidth: .infinity)
    }

    private var cardColumn: some View {
        VStack(spacing: 0) {
            cardHeader
            MenuPillTabs(tabs: tabs, selection: tab, select: selectTab)
                .padding(.horizontal, 16).padding(.bottom, 14)
            Rectangle().fill(Theme.line).frame(height: 1)
            FocusScroll {
                VStack(alignment: .leading, spacing: 20) { content }
                    .padding(.horizontal, 18).padding(.vertical, 18)
                    .environment(\.menuPageTitle, page ?? "")
                    .id(page ?? tab)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
        }
        .environment(\.menuRegular, true)
    }

    /// The top of the card: Back (on a page), what this is, and a Close that cannot be missed (a labelled capsule, 44 points tall).
    private var cardHeader: some View {
        let current = tabs.first { $0.id == tab }?.title ?? title
        return HStack(spacing: 12) {
            if page != nil {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                        Text(backTitle).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                    .foregroundStyle(Theme.accent).padding(.horizontal, 14).frame(height: 44)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .focusTarget("menu-back", radius: 22, scale: 1.0, action: back)
                .accessibilityLabel("Back to \(backTitle)")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(page ?? current).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
                if page == nil, let subtitle { Text(subtitle).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1) }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let toggleSize {
                Button(action: toggleSize) {
                    Image(systemName: sizeIsLarge ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                        .frame(width: 44, height: 44).background(Circle().fill(Theme.panelHigh)).overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .coachTarget("menu-size")
                .focusTarget("menu-size", radius: 22, scale: 1.0, action: toggleSize)
                .accessibilityLabel(sizeIsLarge ? "Make the menu smaller" : "Make the menu bigger")
            }
            Button(action: close) {
                HStack(spacing: 7) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                    Text("Close").font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(Theme.text).padding(.horizontal, 18).frame(height: 44)
                .background(Capsule().fill(Theme.panelHigh)).overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .focusTarget("menu-close", radius: 22, scale: 1.0, action: close)
            .accessibilityLabel("Close menu")
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
    }

    // MARK: Wide

    private func wide(width: CGFloat) -> some View {
        let railWidth: CGFloat = 96
        let current = tabs.first { $0.id == tab }?.title ?? title
        return HStack(spacing: 0) {
            MenuRail(tabs: tabs, selection: tab, select: selectTab).frame(width: railWidth)
            Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea()
            VStack(spacing: 0) {
                header(heading: page ?? current, detail: page == nil ? subtitle : nil)
                Divider().overlay(Theme.line)
                FocusScroll {
                    VStack(alignment: .leading, spacing: 16) { content }
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .environment(\.menuPageTitle, page ?? "")
                        .id(page ?? tab)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                }
            }
        }
    }

    /// The top of the content: Back (on a page), the heading, the game's name, and Close.
    private func header(heading: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            if page != nil {
                Button(action: back) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold))
                        Text(backTitle).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                    .foregroundStyle(Theme.accent).padding(.horizontal, 10).frame(height: 34)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .focusTarget("menu-back", radius: 17, scale: 1.0, action: back)
                .accessibilityLabel("Back to \(backTitle)")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(heading).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8).layoutPriority(2)
                if let detail { Text(detail).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34).background(Circle().fill(Theme.panelHigh)).overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close menu")
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 8)
    }

    // MARK: Narrow

    private var narrow: some View {
        VStack(spacing: 0) {
            titleBar
            if page == nil { MenuTabBar(tabs: tabs, selection: tab, select: selectTab).transition(.opacity) }
            Divider().overlay(Theme.line)
            FocusScroll {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(.horizontal, 14).padding(.vertical, 14)
                    .environment(\.menuPageTitle, page ?? "")
                    .id(page ?? tab)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
        }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            if let page {
                Button(action: back) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold))
                        Text(backTitle).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                    .foregroundStyle(Theme.accent).padding(.horizontal, 10).frame(height: 34)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .focusTarget("menu-back", radius: 17, scale: 1.0, action: back)
                .accessibilityLabel("Back to \(backTitle)")
                Text(page).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 21, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).layoutPriority(2)
                    if let subtitle { Text(subtitle).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1) }
                }
            }
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34).background(Circle().fill(Theme.panelHigh)).overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close menu")
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
    }
}
