// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// What the screens use to dress up for a holiday without knowing which one it is: each holiday supplies its own set (Halloween: bats, pumpkins, cobwebs; Thanksgiving: falling leaves,
// a turkey, acorns, leaf piles), and these pick the right one for the look that is on. With no holiday on they draw nothing.

/// What moves behind the text: bats at Halloween, falling leaves at Thanksgiving.
struct FestiveSky: View {
    var body: some View {
        switch ThemeStore.shared.palette.decor {
        case .halloween: BatsLayer()
        case .thanksgiving: LeavesLayer()
        case .none: EmptyView()
        }
    }
}

/// The corners of the screen: cobwebs and a spider, or heaps of leaves and one hanging on a thread.
struct FestiveCorners: View {
    var body: some View {
        let decor = ThemeStore.shared.palette.decor
        if decor != .none {
            GeometryReader { geo in
                let size = max(90, min(170, min(geo.size.width, geo.size.height) * 0.3))
                Color.clear
                    .overlay(alignment: .topLeading) {
                        if decor == .halloween { HalloweenWeb(corner: .topLeading, size: size, spider: true) } else { HarvestCorner(corner: .topLeading, size: size, hanging: true) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if decor == .halloween { HalloweenWeb(corner: .bottomTrailing, size: size * 0.8) } else { HarvestCorner(corner: .bottomTrailing, size: size * 0.8) }
                    }
            }
        }
    }
}

/// What fills the empty end of the games shelf.
struct FestivePatch: View {
    var height: CGFloat
    var body: some View {
        switch ThemeStore.shared.palette.decor {
        case .halloween: HalloweenPatch(height: height)
        case .thanksgiving: HarvestPatch(height: height)
        case .none: EmptyView()
        }
    }
}

extension View {
    /// A small thing sitting on the corner of the Porthole logo: a little pumpkin, or an acorn.
    func festiveLogoBadge(size: CGFloat) -> some View {
        overlay(alignment: .bottomTrailing) {
            switch ThemeStore.shared.palette.decor {
            case .halloween: HalloweenPumpkin(size: size, face: .cute).rotationEffect(.degrees(-10)).offset(x: 7, y: 5)
            case .thanksgiving: HarvestAcorn(size: size).rotationEffect(.degrees(-12)).offset(x: 6, y: 5)
            case .none: EmptyView()
            }
        }
    }

    /// Something sitting on the top edge of a card: a jack-o'-lantern, or a turkey in a pilgrim hat.
    func festiveCardSitter(enabled: Bool = true) -> some View {
        overlay(alignment: .topTrailing) {
            if enabled {
                switch ThemeStore.shared.palette.decor {
                case .halloween: HalloweenPumpkin(size: 34, face: .grin, interactive: true).rotationEffect(.degrees(7)).offset(x: -44, y: -22)
                case .thanksgiving: HarvestTurkey(size: 40).offset(x: -44, y: -26).allowsHitTesting(false)
                case .none: EmptyView()
                }
            }
        }
        .overlay { if enabled, ThemeStore.shared.palette.decor == .halloween { HalloweenCardGlow() } }
    }
}
