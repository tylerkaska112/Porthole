// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Every achievement of the game that is running, with what has been unlocked. Read from the files Steam's client keeps on the device, so it works in the game
/// (the app's own connection to Steam is closed then) and updates while the menu is open; how common each one is comes from Steam's public numbers when they can be reached.
struct AchievementsTab: View {
    @ObservedObject var model: GameMenuModel

    @State private var list: [SteamAchievement] = []
    @State private var loaded = false
    @State private var shares: [String: Double] = [:]
    @State private var toasts = AchievementToastCenter.enabled

    private var appID: Int { model.steamAppID ?? 0 }
    private var steamFolder: URL { AppModel.prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true) }

    var body: some View {
        if !loaded {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding()
        } else if list.isEmpty {
            Text("No achievement list for this game yet. Steam's client saves it the first time the game is started with it.")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
        } else {
            let parts = steamSortAchievements(list)
            summary(unlocked: parts.unlocked.count, total: list.count)
            if !parts.unlocked.isEmpty { MenuCard(title: "Unlocked") { rows(parts.unlocked) } }
            if !parts.locked.isEmpty { MenuCard(title: "Still to unlock") { rows(parts.locked) } }
        }
        MenuCard(title: "Pop-ups", footer: "When Steam records an achievement while you play, a pop-up shows at the top of the screen. It reads Steam's own record on this device; it needs no connection.") {
            MenuToggleRow(title: "Pop-ups for unlocked achievements", isOn: Binding(get: { toasts }, set: { toasts = $0; AchievementToastCenter.enabled = $0 }))
            MenuDivider()
            MenuActionRow(title: "Show a test pop-up", symbol: "trophy") { AchievementToastCenter.shared.showTest() }
        }
        Color.clear.frame(height: 0).task { await watch() }
    }

    private func summary(unlocked: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(unlocked) of \(total) unlocked").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
            ProgressView(value: Double(unlocked), total: Double(max(total, 1))).tint(Theme.good)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    @ViewBuilder private func rows(_ items: [SteamAchievement]) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 { MenuDivider() }
            row(item)
        }
    }

    private func row(_ item: SteamAchievement) -> some View {
        let secret = item.hidden && item.unlocked == nil
        var line: [String] = []
        if let date = item.unlocked { line.append("Unlocked " + date.formatted(date: .abbreviated, time: .shortened)) }
        if let share = shares[item.apiName] { line.append(String(format: "%.1f%% of players", share)) }
        return HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: item.iconURL(app: appID)) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Theme.panelHigh.overlay { Image(systemName: "trophy").foregroundStyle(Theme.textDim) } }
            }
            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).opacity(item.unlocked == nil ? 0.75 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(secret ? "Hidden achievement" : item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                if !secret, !item.detail.isEmpty { Text(item.detail).font(.system(size: 12)).foregroundStyle(Theme.textDim).lineLimit(3) }
                if !line.isEmpty { Text(line.joined(separator: " \u{00B7} ")).font(.system(size: 11)).foregroundStyle(item.unlocked == nil ? Theme.textDim : Theme.good) }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 56, alignment: .leading)
        .focusTarget("ach:\(item.apiName)", radius: 8, scale: 1.0) {}
    }

    /// Reads the files now and again every few seconds while the tab is shown, so an achievement earned with the menu open appears in the list.
    private func watch() async {
        guard appID != 0 else { loaded = true; return }
        if shares.isEmpty, let url = URL(string: "\(SteamAPI.host)/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v2/?gameid=\(appID)&format=json") {
            Task {
                if let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 {
                    shares = SteamAchievementParser.percentages(data)
                }
            }
        }
        while !Task.isCancelled {
            let account = SteamService.shared.accountNumber, folder = steamFolder, app = appID
            let found = await Task.detached { SteamLocalAchievements.load(steamFolder: folder, account: account, appID: app) }.value
            if found != list { list = found }
            loaded = true
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}
