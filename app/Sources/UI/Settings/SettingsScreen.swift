// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Settings: a grouped list of pages on the left and the chosen page on the right (one at a time on a narrow screen). Everything is reachable with the D-pad.
struct SettingsScreen: View {
    @Environment(AppRouter.self) private var router
    @Environment(UpdateService.self) private var updates
    @Environment(\.focusScope) private var scope
    private var selection: SettingsPage? {
        get { router.settingsSelection }
        nonmutating set { router.settingsSelection = newValue }
    }
    @AppStorage("f4.setupDone") private var setupDone = false
    @ObservedObject private var problems = ProblemTracker.shared

    /// The list on the left, in groups. A heading above each group says what its pages are about.
    static let sections: [(title: String, pages: [SettingsPage])] = [
        ("Playing", [.display, .performance, .sound, .controls]),
        ("Your games", [.stores, .saves, .storage]),
        ("Connection", [.jit]),
        ("App", [.appearance, .updates, .signing, .advanced]),
        ("Reports and fixes", [.reports, .fixing]),
        ("Help", [.guides, .about, .report]),
    ]
    static let pages: [SettingsPage] = sections.flatMap(\.pages)

    @State private var query = ""
    private var sub: SettingsSub? {
        get { router.settingsSub }
        nonmutating set { router.settingsSub = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 700
            Group {
                if wide {
                    HStack(spacing: 0) {
                        sidebar(wide: true).frame(width: 300)
                        Rectangle().fill(Theme.line).frame(width: 1)
                        detail(wide: true)
                    }
                } else if let page = selection {
                    VStack(alignment: .leading, spacing: 0) {
                        // Inside a page of a page (Advanced > Engine options > ...) the page has its own Back button one level up; a second one here led somewhere else.
                        if sub == nil { PillButton(id: "settings-back", title: "Settings", symbol: "chevron.left") { selection = nil }.padding(.horizontal, 20).padding(.top, 8) }
                        detail(wide: false, page: page)
                    }
                } else {
                    sidebar(wide: false)
                }
            }
            .onAppear {
                // Opens on the first page every time (or the page a link asked for), with the glow on its entry in the list.
                if let page = router.settingsPage { selection = page; router.settingsPage = nil }
                else { selection = wide ? .display : nil; sub = nil }
                scope?.start(at: "set-\((selection ?? .display).rawValue)", force: true)
            }
            .onChange(of: router.settingsPage) { _, page in if let page { selection = page; router.settingsPage = nil } }
            // Opening a page inside a page moves the highlight to its Back button, so the D-pad starts at the top of it.
            .onChange(of: router.settingsSub) { old, new in
                if let new, old?.parent != new { DispatchQueue.main.async { scope?.focused = "set-back" } }
            }
            .onNavBack {
                if wide, let focused = scope?.focused as? String, focused.hasPrefix("set-"), focused != "set-back" { return false }
                if let open = sub {
                    sub = open.parent
                    DispatchQueue.main.async { scope?.focused = open.rowID }
                    return true
                }
                if wide { scope?.focused = "set-\((selection ?? .display).rawValue)"; return true }
                if selection != nil { selection = nil; return true }
                return false
            }
        }
    }

    // MARK: Pieces

    private func choose(_ page: SettingsPage) {
        if selection != page { selection = page; sub = nil }
    }

    private func sidebar(wide: Bool) -> some View {
        FocusScroll {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).padding(.horizontal, 6)
                SearchField(id: "set-search", prompt: "Search settings", text: $query, minWidth: 0)
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(Self.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Theme.label(section.title).padding(.horizontal, 6)
                            ForEach(section.pages) { page in
                                SidebarRow(id: "set-\(page.rawValue)", symbol: page.symbol, tint: page.tint, title: page.title, detail: badge(for: page),
                                           selected: wide && selection == page,
                                           onFocus: wide ? { choose(page) } : nil) {
                                    if wide { scope?.handle(.move(.right)) } else { choose(page) }
                                }
                            }
                        }
                    }
                } else {
                    results(wide: wide)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 16)
            .frame(maxWidth: wide ? .infinity : 640, alignment: .leading).frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
        }
    }

    /// What the search found. A result opens the page that holds the setting.
    private func results(wide: Bool) -> some View {
        let found = SettingsIndex.search(query)
        return VStack(alignment: .leading, spacing: 10) {
            if found.isEmpty {
                Text("Nothing in Settings is called that.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            } else {
                Theme.label("\(found.count) found").padding(.horizontal, 6)
                ForEach(found) { entry in
                    ActionRow(id: "sr-\(entry.id)", symbol: entry.page.symbol, tint: entry.page.tint, title: entry.title, subtitle: entry.path.isEmpty ? nil : entry.path, chevron: false) {
                        open(entry, wide: wide)
                    }
                }
            }
        }
    }

    private func open(_ entry: SettingsIndex.Entry, wide: Bool) {
        query = ""
        selection = entry.page
        sub = entry.sub
        let target: String = entry.sub != nil ? "set-back" : (wide ? "set-\(entry.page.rawValue)" : "settings-back")
        DispatchQueue.main.async { scope?.focused = target }
    }

    private func detail(wide: Bool, page: SettingsPage? = nil) -> some View {
        let shown = page ?? selection
        return FocusScroll {
            Group {
                if let shown { SettingsPageView(page: shown).id(shown) }
                else { Text("Choose a page").foregroundStyle(Theme.textDim).frame(maxWidth: .infinity).padding(.top, 80) }
            }
            .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func badge(for page: SettingsPage) -> String? {
        switch page {
        case .updates: return updates.available != nil ? "1" : nil
        case .guides: return setupDone ? nil : "!"
        case .jit: return BuiltinJIT.hasPairing ? nil : "!"
        case .report: return problems.unseen > 0 ? "\(problems.unseen)" : (CrashEvidence.latestUnreported() != nil ? "!" : nil)
        default: return nil
        }
    }
}

extension SettingsPage {
    var title: String {
        switch self {
        case .display: "Display"
        case .performance: "Performance"
        case .sound: "Sound"
        case .controls: "Controls"
        case .stores: "Stores"
        case .saves: "Saves"
        case .storage: "Storage"
        case .jit: "JIT and connection"
        case .appearance: "Appearance"
        case .updates: "Updates"
        case .signing: "Signing"
        case .advanced: "Advanced"
        case .reports: "Compatibility reports"
        case .fixing: "Fixing problems"
        case .guides: "Setup guide and tips"
        case .about: "About and credits"
        case .report: "Report a problem"
        }
    }
    var symbol: String {
        switch self {
        case .display: "display"
        case .performance: "speedometer"
        case .sound: "speaker.wave.2.fill"
        case .controls: "gamecontroller.fill"
        case .stores: "storefront.fill"
        case .saves: "externaldrive.badge.icloud"
        case .storage: "internaldrive.fill"
        case .jit: "bolt.horizontal.fill"
        case .appearance: "paintpalette.fill"
        case .updates: "arrow.triangle.2.circlepath"
        case .signing: "person.text.rectangle.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        case .reports: "checkmark.seal.fill"
        case .fixing: "wand.and.stars"
        case .guides: "lightbulb.fill"
        case .about: "info.circle.fill"
        case .report: "exclamationmark.bubble.fill"
        }
    }
    var tint: Color {
        switch self {
        case .display: .cyan
        case .performance: .orange
        case .sound: .red
        case .controls: .blue
        case .stores: .indigo
        case .saves: .teal
        case .storage: .orange
        case .jit: .green
        case .appearance: .pink
        case .updates: .mint
        case .signing: .brown
        case .advanced: .gray
        case .reports: .purple
        case .fixing: .yellow
        case .guides: .cyan
        case .about: .gray
        case .report: .red
        }
    }
}

/// A page's content. Each page is one screen of its own; a few are made of two older, smaller ones.
struct SettingsPageView: View {
    let page: SettingsPage

    var body: some View {
        switch page {
        case .display: DisplayPage()
        case .performance: PerformancePage()
        case .sound: SoundPage()
        case .controls: ControlsPage()
        case .stores: StoresSettingsPage()
        case .saves: SavesPage()
        case .storage: StoragePage()
        case .jit: ConnectionPage()
        case .appearance: AppearancePage()
        case .updates: UpdatesPage(mode: .updates)
        case .signing: UpdatesPage(mode: .signing)
        case .advanced: AdvancedPage()
        case .reports: ReportsSettingsPage(mode: .reports)
        case .fixing: ReportsSettingsPage(mode: .fixing)
        case .guides: CombinedPage(title: "Setup guide and tips", symbol: "lightbulb.fill") { SetupPage(); GuidesPage() }
        case .about: AboutPage()
        case .report: ReportProblemPage()
        }
    }
}
