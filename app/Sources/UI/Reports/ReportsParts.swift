// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The pieces the Reports tab and a game's reports page are drawn with. They take plain values (no stores, no network), so the UI preview app can draw them with sample data.

extension ReportsFilter {
    var tint: Color {
        switch self { case .all: Theme.accent; case .great: Theme.good; case .playable: Theme.warn; case .broken: Theme.bad; case .untested: Theme.textDim }
    }
}

/// A coloured bar that shows how a set of games or reports divides between works great, playable, broken and unknown.
struct VerdictBar: View {
    struct Part: Identifiable { let id: String; let amount: Int; let color: Color }
    let parts: [Part]

    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.amount })
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(parts.filter { $0.amount > 0 }) { part in
                    Rectangle().fill(part.color).frame(width: max(4, geo.size.width * CGFloat(part.amount) / CGFloat(total)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 10)
        .background(Theme.panelHigh)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// One filter or choice as a capsule, with an optional count.
struct ReportsChip: View {
    let id: String
    let title: String
    var count: Int?
    let on: Bool
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let count { Text("\(count)").monospacedDigit().opacity(0.75) }
            }
            .font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1).fixedSize()
            .foregroundStyle(on ? Theme.onAccent : Theme.text)
            .padding(.horizontal, 14).frame(minHeight: 38)
            .background(on ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.panel), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusTarget("rs-chip-\(id)", radius: 19, scale: 1.06, action: action)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The card at the top of a list: how the games in it divide between the verdicts.
struct ReportsSummaryCard: View {
    let headline: String
    let detail: String
    let summary: ReportsLogic.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headline).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
            Text(detail).font(.footnote).foregroundStyle(Theme.textDim)
            VerdictBar(parts: [.init(id: "g", amount: summary.great, color: Theme.good), .init(id: "p", amount: summary.playable, color: Theme.warn),
                               .init(id: "b", amount: summary.broken, color: Theme.bad), .init(id: "u", amount: summary.untested, color: Theme.textDim.opacity(0.5))])
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// One game in a list.
struct ReportsRowView: View {
    let item: ReportsItem
    let subtitle: String
    let open: () -> Void

    var body: some View {
        RowBase(id: "rs-\(item.id)", symbol: symbol, tint: tint, title: item.title, subtitle: subtitle, action: open) {
            if let verdict = item.verdict { CompatBadgePill(verdict: verdict, compact: true) }
            else if let past = item.badge.past { CompatPastPill(past: past, compact: true) }
            else { CompatUntestedPill(compact: true) }
        }
    }

    private var symbol: String { item.verdict?.symbol ?? item.badge.past?.symbol ?? "questionmark.circle.fill" }
    private var tint: Color { item.verdict?.color ?? item.badge.past?.color ?? Theme.textDim }
}

/// The top of a game's page: the verdict in large type, what it is based on, and how the reports divide.
struct VerdictHero: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var breakdown: ReportsLogic.Breakdown?
    var yourDevice: (name: String, verdict: CompatVerdict)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 34, weight: .bold)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Text(detail).font(.footnote).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }
            if let breakdown, breakdown.total > 0 {
                VerdictBar(parts: [.init(id: "g", amount: breakdown.great, color: Theme.good), .init(id: "p", amount: breakdown.playable, color: Theme.warn), .init(id: "b", amount: breakdown.broken, color: Theme.bad)])
                HStack(spacing: 16) {
                    legend(breakdown.great, "great", Theme.good)
                    legend(breakdown.playable, "playable", Theme.warn)
                    legend(breakdown.broken, "broken", Theme.bad)
                    Spacer(minLength: 0)
                }
            }
            if let yourDevice {
                HStack(spacing: 8) {
                    Image(systemName: "iphone").foregroundStyle(Theme.textDim)
                    Text("On \(yourDevice.name)").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    CompatBadgePill(verdict: yourDevice.verdict, compact: true)
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(tint.opacity(0.5), lineWidth: 1.5))
        .accessibilityElement(children: .combine)
    }

    private func legend(_ count: Int, _ word: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text("\(count) \(word)").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textDim)
        }
    }
}

/// What people mention most, as small labelled counts.
struct TagCloud: View {
    let tags: [(title: String, count: Int)]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Text(tags[i].title)
                    Text("\(tags[i].count)").monospacedDigit().foregroundStyle(Theme.textDim)
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
            }
        }
    }
}

// MARK: - One report, in full

/// Everything one report says, as values.
struct ReportDetailData {
    struct Row: Identifiable { let id: String; let label: String; let value: String }
    struct Group: Identifiable { let id: String; let title: String; let note: String?; let rows: [Row] }

    var rating: CompatVerdict = .great
    var device = ""
    var date = ""
    /// Set when the report is from an earlier version of the game engine.
    var earlierNote: String?
    var tags: [String] = []
    var groups: [Group] = []
    var comment: String?
}

/// A report opened in full: the verdict, then what happened, what was measured, what it ran on, the settings and the person's note.
struct ReportDetailView: View {
    let data: ReportDetailData

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: data.rating.symbol).font(.system(size: 34, weight: .bold)).foregroundStyle(data.rating.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(data.rating.title).font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                        Text(data.rating.detail).font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Image(systemName: "iphone").foregroundStyle(Theme.textDim)
                    Text(data.device).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    Text(data.date).font(.footnote).foregroundStyle(Theme.textDim)
                }
                if let note = data.earlierNote {
                    Label(note, systemImage: "clock.arrow.circlepath").font(.footnote).foregroundStyle(Theme.warn)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(data.rating.color.opacity(0.5), lineWidth: 1.5))

            if let comment = data.comment, !comment.isEmpty {
                SettingsGroup(title: "Their note") {
                    Text("\u{201C}\(comment)\u{201D}").font(.system(size: 16, design: .rounded)).foregroundStyle(Theme.text).textSelection(.enabled)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                }
            }
            if !data.tags.isEmpty {
                SettingsGroup(title: "They mentioned") {
                    FlowLayout(spacing: 8) {
                        ForEach(data.tags, id: \.self) { tag in
                            Text(tag).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Theme.panel, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            ForEach(data.groups) { group in
                SettingsGroup(title: group.title, note: group.note) {
                    ForEach(group.rows) { row in
                        RowBase(id: "rd-\(group.id)-\(row.id)", title: row.label, action: {}) {
                            Text(row.value).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textDim).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
    }
}
