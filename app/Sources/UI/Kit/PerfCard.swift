// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The in-game performance overlay, drawn from plain values so the UI preview app can show it: a large frame rate with a small graph, and the other numbers as rows with icons.

struct PerfCardRow: Identifiable, Equatable {
    var id: String
    var label: String
    var value: String
    var symbol: String
    var tint: Color?
}

/// The recent frame rates as a line with a soft fill under it.
struct FPSGraph: View {
    let values: [Double]
    var length = 60
    var tint: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            let top = max(60, (values.max() ?? 60).rounded(.up))
            let step = geo.size.width / CGFloat(max(1, length - 1))
            let offset = geo.size.width - CGFloat(max(0, values.count - 1)) * step
            let points: [CGPoint] = values.enumerated().map { i, v in CGPoint(x: offset + CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(min(v, top) / top))) }
            ZStack {
                // A faint guide where 30 FPS is.
                Path { p in let y = geo.size.height * (1 - 30 / CGFloat(top)); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                    .stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                if points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        for pt in points { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.4), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.move(to: points[0]); for pt in points.dropFirst() { p.addLine(to: pt) } }
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

/// Puts its children in columns: a new column starts when the next one would not fit in `maxHeight`.
struct OverlayColumns: SwiftUI.Layout {
    var maxHeight: CGFloat
    var spacing: CGFloat = 2
    var columnSpacing: CGFloat = 16

    private struct Arrangement { var columns: [[Int]] = [[]]; var widths: [CGFloat] = [0]; var heights: [CGFloat] = [0] }

    private func arrange(_ subviews: LayoutSubviews) -> Arrangement {
        var a = Arrangement()
        for (i, view) in subviews.enumerated() {
            let s = view.sizeThatFits(.unspecified)
            let last = a.columns.count - 1
            let gap = a.columns[last].isEmpty ? 0 : spacing
            if !a.columns[last].isEmpty, a.heights[last] + gap + s.height > maxHeight {
                a.columns.append([]); a.widths.append(0); a.heights.append(0)
            }
            let c = a.columns.count - 1
            a.heights[c] += (a.columns[c].isEmpty ? 0 : spacing) + s.height
            a.widths[c] = max(a.widths[c], s.width)
            a.columns[c].append(i)
        }
        return a
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let a = arrange(subviews)
        return CGSize(width: a.widths.reduce(0, +) + columnSpacing * CGFloat(max(0, a.widths.count - 1)), height: a.heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        let a = arrange(subviews)
        var x = bounds.minX
        for (c, column) in a.columns.enumerated() {
            var y = bounds.minY
            for i in column {
                let h = subviews[i].sizeThatFits(.unspecified).height
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: a.widths[c], height: h))
                y += h + spacing
            }
            x += a.widths[c] + columnSpacing
        }
    }
}

struct PerfCardView: View {
    /// The headline number (nil when the frame rate is not one of the chosen numbers).
    var fps: Double?
    var fpsTint: Color?
    let rows: [PerfCardRow]
    var history: [Double] = []
    var showGraph = false
    var asLine = false
    var fontSize: CGFloat = 13
    var opacity: Double = 0.75
    /// The most height the rows may take before they start a new column.
    var tallest: CGFloat = 10_000
    /// The developer's text block, to the right of the card's numbers.
    var extraText: String?

    private var headTint: Color { fpsTint ?? ((fps ?? 0) > 0 ? Theme.good : .white.opacity(0.6)) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group { if asLine { line } else { card } }
            if let extraText, !extraText.isEmpty {
                Text(extraText).font(.system(size: max(9, fontSize - 3), design: .monospaced)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(.horizontal, asLine ? 11 : 9).padding(.vertical, asLine ? 6 : 7)
        .background(RoundedRectangle(cornerRadius: asLine ? 20 : 12, style: .continuous).fill(Color.black.opacity(opacity * 0.82)))
        .overlay(RoundedRectangle(cornerRadius: asLine ? 20 : 12, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }

    /// One line: the frame rate, then every other number, each with its icon.
    private var line: some View {
        HStack(spacing: 10) {
            if let fps { HStack(spacing: 4) { Circle().fill(headTint).frame(width: 7, height: 7); Text(String(format: "%.0f", fps)).foregroundStyle(headTint); Text("FPS").foregroundStyle(.white.opacity(0.55)) } }
            ForEach(rows) { row in
                HStack(spacing: 4) { Image(systemName: row.symbol).font(.system(size: fontSize - 2, weight: .semibold)).foregroundStyle(.white.opacity(0.5)); Text(row.value).foregroundStyle(row.tint ?? .white) }
            }
        }
        .font(.system(size: fontSize, weight: .semibold, design: .rounded).monospacedDigit())
    }

    /// A number in a cell: the value on top, a small label under it (no icon: the label says what it is, and an icon per cell made every column wider). Cells sit in a grid, so a dozen numbers take about as much room as four rows used to.
    private func cell(_ row: PerfCardRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(row.value).font(.system(size: fontSize, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(row.tint ?? .white).lineLimit(1)
            Text(row.label).font(.system(size: max(7, fontSize * 0.7), weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
    }

    private var grid: some View {
        let columns = rows.count <= 3 ? max(1, rows.count) : (rows.count <= 6 ? 3 : 4)
        let chunks = stride(from: 0, to: rows.count, by: columns).map { Array(rows[$0..<min($0 + columns, rows.count)]) }
        return Grid(alignment: .leading, horizontalSpacing: 11, verticalSpacing: 4) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                GridRow { ForEach(chunk) { cell($0) } }
            }
        }
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 11) {
            if fps != nil || showGraph {
                VStack(alignment: .leading, spacing: 3) {
                    if let fps {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.0f", fps)).font(.system(size: fontSize * 2.0, weight: .heavy, design: .rounded).monospacedDigit()).foregroundStyle(headTint)
                                .shadow(color: headTint.opacity(0.5), radius: 5)
                            Text("FPS").font(.system(size: fontSize * 0.75, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    if showGraph { FPSGraph(values: history, tint: headTint).frame(width: max(72, fontSize * 6.5), height: fontSize * 2.2) }
                }
                if !rows.isEmpty { Rectangle().fill(.white.opacity(0.14)).frame(width: 1) }
            }
            if !rows.isEmpty { grid }
        }
        .fixedSize()
    }
}
