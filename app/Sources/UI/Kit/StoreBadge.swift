// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The mark of the store a game came from: the launcher's own logo (Assets.xcassets: StoreSteam, StoreEpic, StoreGog, StoreItch, StoreAmazon), so a card says at a glance where its game was downloaded from.
/// The logos belong to Valve, Epic Games, GOG, itch corp. and Amazon; they are shown only to say which store a game is from.
struct StoreBadge: View {
    let store: GameStore
    var size: CGFloat = 22

    private var asset: String {
        switch store {
        case .steam: "StoreSteam"
        case .epic: "StoreEpic"
        case .gog: "StoreGog"
        case .itch: "StoreItch"
        case .amazon: "StoreAmazon"
        }
    }

    var body: some View {
        Image(asset).resizable().interpolation(.high).scaledToFit()
        .frame(width: size, height: size)
        .accessibilityLabel(store.title)
    }
}

/// The badge on a light round backing, so the dark Epic shield also shows up on a dark picture or panel.
struct StoreBadgeBacked: View {
    let store: GameStore
    var size: CGFloat = 22
    var body: some View {
        StoreBadge(store: store, size: size * 0.72)
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.94), in: Circle())
            .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.04)
    }
}

/// The badge with the store's name next to it, as a chip (a game's page, the details line of the Home hero).
struct StoreChip: View {
    let store: GameStore
    var body: some View {
        HStack(spacing: 6) {
            StoreBadgeBacked(store: store, size: 22)
            Text(store.title).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(.white)
        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
    }
}

/// The badge on the corner of a picture.
struct StoreCorner: View {
    let store: GameStore
    var size: CGFloat = 24
    var body: some View { StoreBadgeBacked(store: store, size: size) }
}
