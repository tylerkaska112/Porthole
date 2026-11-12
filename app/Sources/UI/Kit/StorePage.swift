// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A store's page: the store icons and the controls (search, filter, sort ...) stay docked at the top, and only what is below them scrolls. The controls start a new line when
/// they do not fit (a phone held upright), so none of them has to be scrolled to; held sideways they are one line.
struct StorePage<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // The way across to the other stores is one row; search, filters and sort belong to the store that is open, so they get the row below it.
                FocusScroll(axes: .horizontal) {
                    StoreSwitcher()
                        .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 2)
                }
                .fixedSize(horizontal: false, vertical: true)
                ControlsFlow(spacing: 10) { header }
                    .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            .frame(maxWidth: 1400).frame(maxWidth: .infinity)
            .background(Theme.panel.opacity(0.35))
            FocusScroll {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 18)
                    .frame(maxWidth: 1400).frame(maxWidth: .infinity)
            }
        }
    }
}


/// Lays its children out left to right, and starts a new line when the next one does not fit. When it had to wrap, the children marked `Flexible` (the search field) take
/// the room left on their line, so each line ends at the edge; on one line nothing is stretched.
struct ControlsFlow: SwiftUI.Layout {
    var spacing: CGFloat = 10

    struct Flexible: LayoutValueKey { static let defaultValue = false }

    private func lines(_ width: CGFloat, _ subviews: Subviews) -> [[Int]] {
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let w = view.sizeThatFits(.unspecified).width
            if x > 0, x + spacing + w > width { lines.append([]); x = 0 }
            x += (x > 0 ? spacing : 0) + w
            lines[lines.count - 1].append(i)
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? .infinity
        let all = lines(width, subviews)
        var height: CGFloat = 0, widest: CGFloat = 0
        for line in all {
            let sizes = line.map { subviews[$0].sizeThatFits(.unspecified) }
            height += sizes.map(\.height).max() ?? 0
            widest = max(widest, sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, line.count - 1)))
        }
        height += spacing * CGFloat(max(0, all.count - 1))
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let all = lines(bounds.width, subviews)
        var y = bounds.minY
        for line in all {
            let sizes = line.map { subviews[$0].sizeThatFits(.unspecified) }
            let used = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, line.count - 1))
            let flexible = line.filter { subviews[$0][Flexible.self] }
            let extra = all.count > 1 && !flexible.isEmpty ? max(0, bounds.width - used) / CGFloat(flexible.count) : 0
            let height = sizes.map(\.height).max() ?? 0
            var x = bounds.minX
            for (k, i) in line.enumerated() {
                let w = sizes[k].width + (subviews[i][Flexible.self] ? extra : 0)
                subviews[i].place(at: CGPoint(x: x, y: y + (height - sizes[k].height) / 2), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: w, height: sizes[k].height))
                x += w + spacing
            }
            y += height + spacing
        }
    }
}
