// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// The Stores tab's front page, drawn from plain values (the app fills them from its launchers, the UI preview app from samples).

/// One launcher on the front page.
struct StoreCardData: Identifiable, Equatable {
    var store: GameStore
    var signedIn: Bool
    var account: String?
    var games = 0
    var installed = 0
    /// 0...1 while one of its games is downloading.
    var downloading: Double?
    var id: String { store.rawValue }
}

/// Up to three launcher badges overlapped inside one square, so five badges never run over a title.
struct OverlappedStoreBadges: View {
    let stores: [GameStore]
    var slot: CGFloat = 52

    var body: some View {
        let shown = Array(stores.prefix(3))
        let size = slot * 0.66
        let step = shown.count > 1 ? (slot - size) / CGFloat(shown.count - 1) : 0
        let start = shown.count > 1 ? -(slot - size) / 2 : 0
        ZStack {
            ForEach(Array(shown.enumerated()), id: \.element) { index, store in
                StoreBadgeBacked(store: store, size: size).offset(x: start + CGFloat(index) * step).zIndex(Double(index))
            }
        }
        .frame(width: slot, height: slot)
        .accessibilityHidden(true)
    }
}

struct StoresHubView: View {
    let cards: [StoreCardData]
    /// The launchers whose badges sit on the "All games" card (the signed in ones first).
    let allBadges: [GameStore]
    let totalGames: Int
    let totalInstalled: Int
    let downloadsSummary: String
    /// 0...1 while something is downloading.
    let downloadsFraction: Double?
    /// The Software card: what is installed, and 0...1 while one is coming down.
    var softwareSummary = "Blender and other programs, downloaded when you want them"
    var softwareFraction: Double?
    let open: (GameStore) -> Void
    let openAll: () -> Void
    let openDownloads: () -> Void
    var openSoftware: () -> Void = {}
    /// Stores the person hid (they are not among `cards`), the long-press "Hide" on a card, and the way to get them back.
    var hiddenStores: [GameStore] = []
    var hide: (GameStore) -> Void = { _ in }
    var showHidden: () -> Void = {}

    private var connected: Int { cards.filter(\.signedIn).count }
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        let tight = vSize == .compact
        return VStack(alignment: .leading, spacing: tight ? 12 : 18) {
            header(tight: tight)
            // Held sideways there is no height to spare: the two wide cards share a row.
            if tight { HStack(spacing: 14) { allCard; downloadsCard }.fixedSize(horizontal: false, vertical: true) } else { allCard; downloadsCard }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(cards) { card in storeCard(card).festiveCardSitter(enabled: card.store == .steam) }
            }
            if cards.isEmpty && !hiddenStores.isEmpty {
                Text("Every store is hidden. Show the ones you use to see their libraries here.").font(.system(size: 14, design: .rounded)).foregroundStyle(Theme.textDim)
            }
            softwareCard
            if !hiddenStores.isEmpty { hiddenRow }
            Text("More stores will show up here as Porthole learns them.").font(.footnote).foregroundStyle(Theme.textDim).padding(.top, 2)
        }
    }

    // MARK: Pieces

    private func header(tight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stores").font(.system(size: tight ? 28 : 34, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
            Text(connected == 0 ? "Sign in to a store and its games show up here, ready to download."
                                : "\(connected) of \(cards.count) stores connected. Open one to see its library.")
                .font(.system(size: 15, design: .rounded)).foregroundStyle(Theme.textDim)
        }
        .padding(.bottom, 2)
    }

    /// "3 stores hidden: Amazon Games, EA app" with the way back to Settings > Stores, where each can be shown again.
    private var hiddenRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textDim)
            Text("\(hiddenStores.count) hidden: \(hiddenStores.map(\.title).joined(separator: ", "))")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(2)
            Spacer(minLength: 6)
            PillButton(id: "stores-show-hidden", title: "Show", symbol: "eye", action: showHidden)
        }
        .padding(.horizontal, 4)
    }

    private var allCard: some View {
        Button(action: openAll) {
            HStack(spacing: 16) {
                OverlappedStoreBadges(stores: allBadges, slot: 58)
                VStack(alignment: .leading, spacing: 6) {
                    Text("All games").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    if totalGames == 0 {
                        Text("No games yet").font(.system(size: 14, design: .rounded)).foregroundStyle(Theme.textDim)
                    } else {
                        FlowLayout(spacing: 12) {
                            stat("\(totalGames)", totalGames == 1 ? "game" : "games")
                            stat("\(totalInstalled)", "installed")
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.textDim)
            }
            .padding(vSize == .compact ? 14 : 18).frame(maxWidth: .infinity, minHeight: vSize == .compact ? 76 : 92, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.26), Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1.2))
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPress())
        .focusTarget("store-all", radius: 22, scale: 1.012, action: openAll)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: String, _ word: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.system(size: 15, weight: .heavy, design: .rounded).monospacedDigit()).foregroundStyle(Theme.text)
            Text(word).font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim)
        }
        .lineLimit(1).fixedSize()
    }

    private func storeCard(_ card: StoreCardData) -> some View {
        let tint = card.store.tint
        return Button { open(card.store) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    StoreBadgeBacked(store: card.store, size: 52).shadow(color: tint.opacity(card.signedIn ? 0.6 : 0.25), radius: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.store.title).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                        HStack(spacing: 6) {
                            Circle().fill(card.signedIn ? Theme.good : Theme.textDim.opacity(0.6)).frame(width: 7, height: 7)
                            Text(card.signedIn ? (card.account.map { "Signed in as \($0)" } ?? "Signed in") : "Not signed in")
                                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.textDim)
                }
                if card.signedIn { library(card, tint: tint) } else { signInHint }
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(card.signedIn ? 0.24 : 0.1), Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(tint.opacity(card.signedIn ? 0.45 : 0.18), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPress())
        .focusTarget("store-\(card.store.rawValue)", radius: 22, scale: 1.012) { open(card.store) }
        .contextMenu {
            Button { hide(card.store) } label: { Label("Hide \(card.store.title)", systemImage: "eye.slash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Hide \(card.store.title)") { hide(card.store) }
    }

    /// How much of the library is on the device, and a download in progress.
    private func library(_ card: StoreCardData, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.games == 0 {
                Text("No games yet").font(.system(size: 14, design: .rounded)).foregroundStyle(Theme.textDim)
            } else {
                HStack(spacing: 14) {
                    stat("\(card.games)", card.games == 1 ? "game" : "games")
                    stat("\(card.installed)", "installed")
                }
                Capsule().fill(.white.opacity(0.1)).frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in Capsule().fill(tint).frame(width: max(5, geo.size.width * CGFloat(card.installed) / CGFloat(max(1, card.games)))) }
                    }
            }
            if let fraction = card.downloading {
                Label("Downloading \(Int(fraction * 100))%", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent)
            }
        }
    }

    private var signInHint: some View {
        HStack(spacing: 8) {
            Text("Sign in to see your games").font(.system(size: 14, design: .rounded)).foregroundStyle(Theme.textDim)
            Spacer(minLength: 4)
            Text("Sign in").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 12).padding(.vertical, 5).background(Theme.accentGradient, in: Capsule())
        }
    }

    private var softwareCard: some View {
        Button(action: openSoftware) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.accentGradient).frame(width: 46, height: 46)
                    .background(Theme.accent.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text("Software").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                    Text(softwareSummary).font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(2)
                    if let softwareFraction {
                        Capsule().fill(.white.opacity(0.1)).frame(height: 5)
                            .overlay(alignment: .leading) { GeometryReader { geo in Capsule().fill(Theme.accentGradient).frame(width: max(5, geo.size.width * softwareFraction)) } }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(softwareFraction == nil ? Theme.line : Theme.accent.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPress())
        .focusTarget("store-software", radius: 20, scale: 1.012, action: openSoftware)
        .accessibilityElement(children: .combine)
    }

    private var downloadsCard: some View {
        Button(action: openDownloads) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.accentGradient).frame(width: 46, height: 46)
                    .background(Theme.accent.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloads").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                    Text(downloadsSummary).font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.textDim).lineLimit(2)
                    if let downloadsFraction {
                        Capsule().fill(.white.opacity(0.1)).frame(height: 5)
                            .overlay(alignment: .leading) { GeometryReader { geo in Capsule().fill(Theme.accentGradient).frame(width: max(5, geo.size.width * downloadsFraction)) } }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(downloadsFraction == nil ? Theme.line : Theme.accent.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPress())
        .focusTarget("store-downloads", radius: 20, scale: 1.012, action: openDownloads)
        .accessibilityElement(children: .combine)
    }
}

/// A card gives a little under the finger.
struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.985 : 1).animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
