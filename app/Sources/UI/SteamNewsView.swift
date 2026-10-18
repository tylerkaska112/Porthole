// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A Steam game's announcements and patch notes, newest first. Steam's public news feed; no sign-in. In the app a tap opens the post in the browser; inside a running game
/// it only reads (leaving the game for the browser would not be what anyone wants).
struct SteamNewsList: View {
    let appID: Int
    var canOpen = true
    @State private var items: [SteamNewsItem]?
    @State private var failed = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let items {
                if items.isEmpty {
                    Text("Steam has no news for this game.").font(.footnote).foregroundStyle(Theme.textDim)
                } else {
                    ForEach(items) { card($0) }
                }
            } else if failed {
                Text("Steam's news could not be loaded. Check your internet connection.").font(.footnote).foregroundStyle(Theme.warn)
                Button("Try again") { Task { await load() } }.font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent).frame(minHeight: 44)
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding()
            }
        }
        .task(id: appID) { await load() }
    }

    private func load() async {
        failed = false
        if let found = await SteamInfoStore.shared.news(appID: appID) { items = found } else { failed = true }
    }

    private func card(_ item: SteamNewsItem) -> some View {
        let open = { if canOpen, let url = item.url { openURL(url) } }
        return VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
            Text([RelativeDateTimeFormatter().localizedString(for: item.date, relativeTo: Date()), item.source].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                .font(.system(size: 12)).foregroundStyle(Theme.accent)
            if !item.summary.isEmpty {
                Text(item.summary).font(.system(size: 13)).foregroundStyle(Theme.textDim).lineLimit(6).multilineTextAlignment(.leading)
            }
            if canOpen, item.url != nil {
                Text("Read on Steam").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .focusTarget("news-\(item.id)", radius: 12, scale: 1.0, action: open)
        .accessibilityElement(children: .combine)
    }
}
