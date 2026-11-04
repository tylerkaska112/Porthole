// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The two layouts of the Reports tab, drawn from plain values: the list of games, and one game's reports. ReportsScreen.swift fetches the data and supplies the actions.

// MARK: - The list

/// Summary, filters and the games, for My games and All games.
struct ReportsListLayout<Footer: View>: View {
    @Binding var filter: ReportsFilter
    @Binding var order: ReportsOrder
    @Binding var query: String
    let headline: String
    let detail: String
    let summary: ReportsLogic.Summary
    let items: [ReportsItem]
    /// The text under a game's name.
    let subtitle: (ReportsItem) -> String
    let open: (ReportsItem) -> Void
    var more: ((ReportsItem) -> Void)?
    @ViewBuilder var footer: Footer

    private func count(_ f: ReportsFilter) -> Int? {
        switch f { case .all: summary.total; case .great: summary.great; case .playable: summary.playable; case .broken: summary.broken; case .untested: summary.untested }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReportsSummaryCard(headline: headline, detail: detail, summary: summary)
            FlowLayout(spacing: 8) {
                ForEach(ReportsFilter.allCases) { f in
                    ReportsChip(id: f.rawValue, title: f.title, count: count(f), on: filter == f, tint: f.tint) { filter = f }
                }
            }
            FlowLayout(spacing: 10) {
                SegmentedPills(options: ReportsOrder.allCases.map { .init(id: $0.rawValue, title: $0.title) }, selection: order.rawValue) { order = ReportsOrder(rawValue: $0) ?? .popular }
                SearchField(id: "rs-search", prompt: "Search games", text: $query, minWidth: 200)
            }
            LazyVGrid(columns: Layout.panelGrid, spacing: 10) {
                ForEach(items) { item in
                    ReportsRowView(item: item, subtitle: subtitle(item)) { open(item) }
                        .onAppear { if item.id == items.last?.id { more?(item) } }
                }
            }
            footer
        }
    }
}

// MARK: - One game

/// Everything a game's reports page shows, as values.
struct GameReportsData {
    struct Device: Identifiable { let id: String; let name: String; let verdict: CompatVerdict; let reports: Int; let yours: Bool }
    struct Line: Identifiable { let id: Int; let rating: CompatVerdict; let title: String; let subtitle: String; let earlier: Bool }
    struct Fact: Identifiable { let id: String; let title: String; let value: String }

    var heroSymbol = "questionmark.circle.fill"
    var heroTint: Color = Theme.textDim
    var heroTitle = "Not yet tested"
    var heroDetail = ""
    /// What the verdict means, when it needs saying (an earlier engine's, or none yet).
    var note: String?
    var breakdown: ReportsLogic.Breakdown?
    var yourDevice: (name: String, verdict: CompatVerdict)?
    var tags: [(title: String, count: Int)] = []
    var factsTitle = ""
    var facts: [Fact] = []
    var devices: [Device] = []
    var lines: [Line] = []
    /// There are more reports on the server than the page holds.
    var canLoadMore = false
}

struct GameReportsLayout: View {
    let data: GameReportsData
    /// The "Write a report" button; nil when the game is not in the library.
    var writeTitle: String?
    var writeSubtitle: String?
    var writeProminent = false
    var write: () -> Void = {}
    @Binding var verdictFilter: CompatVerdict?
    @Binding var myDeviceOnly: Bool
    var hasDevice = false
    @Binding var showDetail: Bool
    @Binding var showEarlier: Bool
    var loading = false
    /// Opens one report in full.
    var openReport: (Int) -> Void = { _ in }
    var more: () -> Void = {}
    /// The width from which the page has two columns.
    var twoColumnsFrom: CGFloat = 780

    private var current: [GameReportsData.Line] { data.lines.filter { !$0.earlier && (verdictFilter == nil || $0.rating == verdictFilter) } }
    private var earlier: [GameReportsData.Line] { data.lines.filter(\.earlier) }

    /// Two columns (the verdict and what people say on the left, the reports on the right) once there is room for them.
    @State private var width: CGFloat = 0

    var body: some View {
        Group {
            if width >= twoColumnsFrom {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 18) { overview }.frame(width: 340)
                    VStack(alignment: .leading, spacing: 18) { reports }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) { overview; reports }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @ViewBuilder private var overview: some View {
        VerdictHero(symbol: data.heroSymbol, tint: data.heroTint, title: data.heroTitle, detail: data.heroDetail, breakdown: data.breakdown, yourDevice: data.yourDevice)
        if let note = data.note { Text(note).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
        if let writeTitle {
            ActionRow(id: "cg-write", symbol: "square.and.pencil", title: writeTitle, subtitle: writeSubtitle, chevron: false, prominent: writeProminent) { write() }
        }
        if !data.tags.isEmpty {
            SettingsGroup(title: "What people mention") { TagCloud(tags: data.tags).padding(.horizontal, 4) }
        }
        if !data.facts.isEmpty {
            SettingsGroup(title: data.factsTitle) {
                ForEach(data.facts) { fact in
                    RowBase(id: "cg-s-\(fact.id)", title: fact.title, action: {}) {
                        Text(fact.value).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textDim)
                    }
                }
            }
        }
        if !data.devices.isEmpty {
            SettingsGroup(title: "By device") {
                ForEach(data.devices) { d in
                    RowBase(id: "cg-d-\(d.id)", symbol: "iphone", title: d.name, subtitle: d.yours ? "yours" : nil, action: {}) {
                        HStack(spacing: 8) { CompatBadgePill(verdict: d.verdict, compact: true); Text("\(d.reports)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textDim) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var reports: some View {
        SettingsGroup(title: "Reports") {
            FlowLayout(spacing: 8) {
                ReportsChip(id: "v-all", title: "All", on: verdictFilter == nil) { verdictFilter = nil }
                ForEach(CompatVerdict.allCases) { v in
                    ReportsChip(id: "v-\(v.rawValue)", title: v.short, count: data.breakdown?.count(v), on: verdictFilter == v, tint: v.color) { verdictFilter = verdictFilter == v ? nil : v }
                }
                if hasDevice { ReportsChip(id: "mine", title: "My device", on: myDeviceOnly) { myDeviceOnly.toggle() } }
                ReportsChip(id: "detail", title: "Details", on: showDetail) { showDetail.toggle() }
            }
            ForEach(current) { line in lineRow(line) }
            if current.isEmpty && !loading {
                Text(myDeviceOnly ? "No reports from your device yet." : (verdictFilter == nil ? "No reports on this version yet." : "No reports like that."))
                    .foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
            if loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding() }
            else if data.canLoadMore { ActionRow(id: "cg-more", symbol: "ellipsis.circle", title: "Show more", chevron: false) { more() } }
        }
        if !earlier.isEmpty {
            SettingsGroup(title: "Earlier versions", note: "Sent from older versions of the game engine. They are kept for reference and do not count toward the verdict.") {
                ActionRow(id: "cg-earlier", symbol: showEarlier ? "chevron.up" : "chevron.down", title: showEarlier ? "Hide \(earlier.count) earlier report\(earlier.count == 1 ? "" : "s")" : "Show \(earlier.count) earlier report\(earlier.count == 1 ? "" : "s")", chevron: false) { showEarlier.toggle() }
                if showEarlier { ForEach(earlier) { lineRow($0) } }
            }
        }
    }

    private func lineRow(_ line: GameReportsData.Line) -> some View {
        RowBase(id: "cg-r-\(line.id)", symbol: line.rating.symbol, tint: line.rating.color, title: line.title, subtitle: line.subtitle,
                info: "Press to read the whole report: what was measured, the device and settings, and their note. You can flag it from there.", action: { openReport(line.id) }) {
            CompatBadgePill(verdict: line.rating, compact: true)
        }
    }
}
