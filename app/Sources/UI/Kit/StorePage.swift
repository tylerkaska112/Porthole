// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A store's page: the controls (switch store, search, filter, sort ...) stay docked at the top in one row, and only what is below them scrolls. A row too wide for the screen
/// scrolls sideways by itself, and follows the focus when a controller moves along it.
struct StorePage<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                FocusScroll(axes: .horizontal) {
                    HStack(spacing: 10) { header }
                        .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 10)
                }
                .fixedSize(horizontal: false, vertical: true)
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
