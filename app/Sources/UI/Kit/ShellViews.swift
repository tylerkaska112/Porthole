// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

struct ShellTab: Identifiable, Equatable {
    let id: String
    var title: String
    var symbol: String
}

/// The brand mark: the porthole from the app icon, with the sea inside (a transparent picture, drawn by tools/make_icon.swift).
struct PortholeMark: View {
    var size: CGFloat = 34
    /// From the asset catalog; the simulator preview has the same picture as a plain file in its bundle.
    private static let picture: UIImage? = UIImage(named: "PortholeMark")
        ?? Bundle.main.path(forResource: "PortholeMark", ofType: "png").flatMap { UIImage(contentsOfFile: $0) }

    var body: some View {
        Group {
            if let picture = Self.picture { Image(uiImage: picture).resizable().interpolation(.high).scaledToFit() } else { Color.clear }
        }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.05)
            .accessibilityHidden(true)
    }
}

/// The frame of the app: one slim bar along the top (the brand mark, the sections as plain words that scroll sideways when they do not fit, and the clock),
/// and the current section's content under it. The same bar on a phone and an iPad.
struct AppShell<Content: View>: View {
    let tabs: [ShellTab]
    @Binding var selection: String
    var showHints = false
    /// The question mark in the bar: explains the screen that is open. Nil hides it.
    var onHelp: (() -> Void)?
    @ViewBuilder var content: Content
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    private var roomy: Bool { hSize == .regular }

    @State private var barBottom: CGFloat = 0
    /// The line under the chosen section slides from one to the next.
    @Namespace private var tabLine

    var body: some View {
        ZStack {
            AmbientBackdrop()
            VStack(spacing: 0) {
                // Above the section's content, always: a page whose picture reaches up under the bar (a game's page in Stores) must not sit on top of it and take its taps.
                topBar.zIndex(1)
                    .background(GeometryReader { g in Color.clear.preference(key: BarBottomKey.self, value: g.frame(in: .named("shell")).maxY) })
                SectionFade { content }.id(selection)
                if showHints { ControllerHints(previous: neighbour(-1), next: neighbour(1)).padding(.vertical, 8) }
            }
            // Bats hanging from the bar's lower edge (Halloween): in the small gap under the bar, over nothing that has words.
            HalloweenRoost(barBottom: barBottom)
        }
        .coordinateSpace(name: "shell")
        .onPreferenceChange(BarBottomKey.self) { barBottom = $0 }
    }

    /// The title of the section LB (-1) or RB (+1) leads to, wrapping round as the buttons do.
    private func neighbour(_ step: Int) -> String? {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == selection }) else { return nil }
        return tabs[(i + step + tabs.count) % tabs.count].title
    }

    private var topBar: some View {
        HStack(spacing: roomy ? 22 : 12) {
            HStack(spacing: 10) {
                PortholeMark(size: vSize == .compact ? 30 : 38)
                    .festiveLogoBadge(size: vSize == .compact ? 15 : 19)
                if roomy || vSize == .compact { Text("Porthole").font(.system(size: 21, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1).fixedSize() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Porthole")
            tabStrip
            HStack(spacing: roomy ? 14 : 8) {
                if let onHelp { HelpChip(action: onHelp) }
                if roomy || vSize == .compact { Clock() }   // upright on a phone the system bar already shows the time
            }
            .fixedSize()
        }
        .padding(.horizontal, roomy ? 32 : 16).padding(.top, vSize == .compact ? 4 : 10).padding(.bottom, vSize == .compact ? 2 : 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The sections. A controller's shoulder buttons step through them, so the bar says so: LB sits right before the first section and RB right after the last one
    /// (next to Settings), not at the far end of the bar. Only when the sections do not all fit do they scroll sideways, with the two glyphs held at the ends.
    private var tabStrip: some View {
        ViewThatFits(in: .horizontal) {
            glyphed { tabRow(tight: false).padding(.horizontal, 6).padding(.vertical, 6) }
            glyphed { tabRow(tight: true).padding(.horizontal, 2).padding(.vertical, 6).background(PointerScroll()) }   // a narrow phone: tighter sections before anything scrolls
            glyphed {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { tabRow(tight: true).padding(.horizontal, 2).padding(.vertical, 6) }
                        .onChange(of: selection) { _, id in withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// LB before the sections, RB after them.
    private func glyphed<Row: View>(@ViewBuilder _ row: () -> Row) -> some View {
        HStack(spacing: 6) {
            if showHints { ShoulderGlyph(text: ControllerInput.shared.kind.glyph("LB")) }
            row()
            if showHints { ShoulderGlyph(text: ControllerInput.shared.kind.glyph("RB")) }
        }
    }

    private func tabRow(tight: Bool) -> some View {
        HStack(spacing: roomy ? 10 : 2) {
            ForEach(tabs) { tab in TabPill(tab: tab, selected: selection == tab.id, roomy: roomy, tight: tight, line: tabLine) { selection = tab.id }.id(tab.id) }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selection)
    }
}

/// The question mark in the bar.
private struct HelpChip: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark.circle").font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.textDim)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusTarget("shell-help", radius: 22, scale: 1.08, action: action)
        .accessibilityLabel("Help for this screen")
    }
}

private struct ShoulderGlyph: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(Theme.textDim)
            .padding(.horizontal, 6).padding(.vertical, 3).background(Theme.panel, in: Capsule())
    }
}

/// The time, on the right of the bar.
private struct Clock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, format: .dateTime.hour().minute()).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.text)
        }
    }
}

/// A section name in the bar: plain words, the chosen one bright with a line under it.
struct TabPill: View {
    let tab: ShellTab
    let selected: Bool
    var roomy = true
    /// A narrow phone with the controller hints on: the words a little smaller and closer so all of them fit beside LB and RB.
    var tight = false
    /// Shared by the sections of one bar, so the line under the chosen one moves between them.
    var line: Namespace.ID?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tab.title)
                .font(.system(size: roomy ? 19 : (tight ? 14 : 15), weight: selected ? .heavy : .semibold, design: .rounded))
                .foregroundStyle(selected ? Theme.text : Theme.textDim)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, roomy ? 16 : (tight ? 5 : 9)).padding(.vertical, 8)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.2), value: selected)
                .overlay(alignment: .bottom) {
                    if selected {
                        Capsule().fill(Theme.accentGradient).frame(height: 3).padding(.horizontal, roomy ? 16 : (tight ? 5 : 9))
                            .shadow(color: Theme.accent.opacity(0.6 * Theme.glowStrength), radius: 4)
                            .modifier(MatchedLine(line: line))
                    }
                }
        }
        .buttonStyle(.plain)
        // Not a D-pad target on purpose: the sections change with LB and RB (RootView) or a tap, so Up never lands on the bar and Left / Right never wander along it.
        .accessibilityLabel(tab.title)
    }
}


/// Lets the line under the chosen section slide to the next one when a namespace is given.
private struct MatchedLine: ViewModifier {
    let line: Namespace.ID?
    func body(content: Content) -> some View {
        if let line { content.matchedGeometryEffect(id: "tab-line", in: line) } else { content }
    }
}

/// A section's content fades in when it opens, so moving between sections is a soft change and not a cut.
struct SectionFade<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.28)) { shown = true } }
    }
}
