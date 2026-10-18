// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A game's Steam achievements with this account's progress. Read-only: what Steam has recorded, newest unlocks first.
struct SteamAchievementsContent: View {
    let appID: Int
    @ObservedObject var store: SteamStore

    @State private var list: [SteamAchievement]?
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if loading {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding()
            } else if let failure {
                Text(failure).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6)
                ActionRow(id: "sa-retry", symbol: "arrow.clockwise", title: "Try again", chevron: false) { Task { await load() } }
            } else if let list {
                if list.isEmpty {
                    Text("This game has no achievements on Steam.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                } else {
                    let parts = steamSortAchievements(list)
                    summary(unlocked: parts.unlocked.count, total: list.count)
                    if !parts.unlocked.isEmpty { SettingsGroup(title: "Unlocked") { ForEach(parts.unlocked) { row($0) } } }
                    if !parts.locked.isEmpty { SettingsGroup(title: "Still to unlock") { ForEach(parts.locked) { row($0) } } }
                    Text("Shown as Steam has them. Achievements earned while playing here appear after Steam has recorded them.")
                        .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                }
            }
        }
        .task { await load() }
    }

    private func summary(unlocked: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(unlocked) of \(total) unlocked").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
            ProgressView(value: Double(unlocked), total: Double(max(total, 1))).tint(Theme.good)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func row(_ item: SteamAchievement) -> some View {
        let secret = item.hidden && item.unlocked == nil
        return HStack(spacing: 12) {
            AsyncImage(url: item.iconURL(app: appID)) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Theme.panelHigh.overlay { Image(systemName: phase.error == nil ? "trophy" : "trophy.fill").foregroundStyle(Theme.textDim) } }
            }
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(item.unlocked == nil ? 0.7 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(secret ? "Hidden achievement" : item.name).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(2)
                if !secret, !item.detail.isEmpty { Text(item.detail).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(3) }
                if let line = detailLine(item) { Text(line).font(.caption).foregroundStyle(item.unlocked == nil ? Theme.textDim : Theme.good) }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 56)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .focusTarget("sa-\(item.apiName)", radius: 16, scale: 1.012, action: {})
    }

    private func detailLine(_ item: SteamAchievement) -> String? {
        var parts: [String] = []
        if let date = item.unlocked { parts.append("Unlocked " + date.formatted(date: .abbreviated, time: .shortened)) }
        if let percent = item.percent { parts.append(String(format: "%.1f%% of players", percent)) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private func load() async {
        loading = true; failure = nil
        do { list = try await store.achievements(appID) } catch { failure = SteamSignIn.message(error) }
        loading = false
    }
}
