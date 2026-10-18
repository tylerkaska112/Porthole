// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The signed-in person's Steam friends, read only: who is playing what, who is online, and (folded away) who is not. Used in the app and in the in-game Steam tab.
struct SteamFriendsList: View {
    @ObservedObject private var store = SteamFriendsStore.shared
    @State private var showOffline = false
    /// Set to show only the friends who are in this Steam game right now (a game's page); nil shows everyone.
    var onlyIn: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let game = onlyIn {
                gameList(game)
            } else if !store.loaded {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding()
            } else if let error = store.error, store.friends.isEmpty {
                Text(error).font(.footnote).foregroundStyle(Theme.warn)
                button("Try again", symbol: "arrow.clockwise") { Task { await store.refresh(force: true) } }
            } else if store.friends.isEmpty {
                Text("There is nobody on this Steam account's friends list.").font(.footnote).foregroundStyle(Theme.textDim)
            } else {
                summary
                if !store.playing.isEmpty { section("Playing", store.playing) }
                if !store.online.isEmpty { section("Online", store.online) }
                if !store.offline.isEmpty {
                    button(showOffline ? "Hide offline friends" : "Show offline friends (\(store.offline.count))", symbol: showOffline ? "chevron.up" : "chevron.down") { showOffline.toggle() }
                    if showOffline { section("Offline", store.offline) }
                }
                if !store.hasState { Text("Steam did not give online status just now, only names.").font(.footnote).foregroundStyle(Theme.textDim) }
                button(store.loading ? "Refreshing\u{2026}" : "Refresh", symbol: "arrow.clockwise") { Task { await store.refresh(force: true) } }
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    @ViewBuilder private func gameList(_ game: Int) -> some View {
        let here = store.playing(game: game)
        if !store.loaded {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding()
        } else if let error = store.error, store.friends.isEmpty {
            Text(error).font(.footnote).foregroundStyle(Theme.warn)
            button("Try again", symbol: "arrow.clockwise") { Task { await store.refresh(force: true) } }
        } else if here.isEmpty {
            Text("None of your friends are playing this right now.").font(.footnote).foregroundStyle(Theme.textDim)
        } else {
            section("Playing now", here)
        }
    }

    private var summary: some View {
        let online = store.friends.filter(\.isOnline).count, playing = store.playing.count
        return Text("\(store.friends.count) friends \u{00B7} \(online) online" + (playing > 0 ? " \u{00B7} \(playing) playing" : ""))
            .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
    }

    private func section(_ title: String, _ list: [SteamFriend]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Theme.label(title)
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, friend in
                    if index > 0 { Divider().overlay(Theme.line).padding(.leading, 62) }
                    row(friend)
                }
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
    }

    private func row(_ friend: SteamFriend) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: friend.avatarURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Theme.panelHigh.overlay { Image(systemName: "person.fill").foregroundStyle(Theme.textDim) } }
            }
            .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(store.hasState ? friend.status() : "Status not available").font(.system(size: 12))
                    .foregroundStyle(friend.isPlaying ? Theme.good : (friend.isOnline ? Theme.accent : Theme.textDim)).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 56, alignment: .leading)
        .focusTarget("fr-\(friend.id)", radius: 8, scale: 1.0) {}
        .accessibilityElement(children: .combine)
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.accent).padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusTarget("fr-btn-\(title)", radius: 12, scale: 1.0, action: action)
    }
}
