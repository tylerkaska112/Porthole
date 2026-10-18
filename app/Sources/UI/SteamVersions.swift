// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A Steam game's versions (branches, such as a beta) and DLC: what Steam lists for it and what this device has chosen.
/// Choosing does nothing to the files by itself; "Download changes" installs what was chosen (only what differs is fetched).
struct SteamVersionsContent: View {
    let game: SteamStore.Owned
    @ObservedObject var store: SteamStore
    let installed: Bool
    let apply: () -> Void

    @State private var details: SteamGameDetails?
    @State private var loading = true
    @State private var failure: String?
    @State private var password = ""
    @State private var checking = false
    @State private var note: String?

    private var choice: SteamStore.Choice { store.choice(game.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if loading {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding()
            } else if let failure {
                Text(failure).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6)
                ActionRow(id: "sv-retry", symbol: "arrow.clockwise", title: "Try again", chevron: false) { Task { await load() } }
            } else if let details {
                versions(details)
                dlc(details)
                applyGroup
            }
        }
        .task { await load() }
    }

    // MARK: Versions

    private func versions(_ details: SteamGameDetails) -> some View {
        SettingsGroup(title: "Version") {
            ForEach(details.info.branches) { branch in
                let selected = choice.branch == branch.name
                RowBase(id: "sv-b-\(branch.name)", symbol: selected ? "checkmark.circle.fill" : (branch.passwordRequired && !unlocked(branch) ? "lock.fill" : "circle"),
                        tint: selected ? Theme.good : Theme.accent, title: title(branch), subtitle: subtitle(branch), action: { choose(branch) }) { EmptyView() }
            }
            TextFieldRow(id: "sv-password", symbol: "key.fill", title: "Beta password", placeholder: "Have a code?", info: "Some games have private betas. A code from the developer, typed here, opens the beta it belongs to.", secure: false, text: $password)
            if !password.isEmpty {
                ActionRow(id: "sv-unlock", symbol: "lock.open.fill", title: checking ? "Checking\u{2026}" : "Use this password", chevron: false) { unlock() }
            }
            if let note { Text(note).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
        }
    }

    private func title(_ branch: SteamBranch) -> String {
        branch.name == SteamBranch.publicName ? "Normal version" : branch.name
    }

    private func subtitle(_ branch: SteamBranch) -> String {
        var parts: [String] = []
        if let build = branch.buildID { parts.append("Build \(build)") }
        if let date = branch.updated { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if branch.passwordRequired && !unlocked(branch) { parts.append("needs a password") }
        if !branch.description.isEmpty { parts.append(branch.description) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// A password branch counts as open once its password is kept for this game.
    private func unlocked(_ branch: SteamBranch) -> Bool { !(choice.betaPasswords[branch.name] ?? "").isEmpty }

    private func choose(_ branch: SteamBranch) {
        note = nil
        if branch.passwordRequired && !unlocked(branch) { note = "\u{201C}\(branch.name)\u{201D} needs a password. Type it above."; return }
        store.setBranch(game.id, to: branch.name)
    }

    private func unlock() {
        let typed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !checking else { return }
        checking = true; note = nil
        Task {
            defer { checking = false }
            do {
                let branch = try await store.unlockBranch(game.id, password: typed)
                password = ""
                note = "\u{201C}\(branch)\u{201D} is chosen. Download the changes to switch."
            } catch { note = SteamSignIn.message(error) }
        }
    }

    // MARK: DLC

    @ViewBuilder private func dlc(_ details: SteamGameDetails) -> some View {
        if !details.dlc.isEmpty {
            SettingsGroup(title: "DLC") {
                ForEach(details.dlc) { item in
                    let owned = item.owned == true
                    ToggleRow(id: "sv-d-\(item.appid)", symbol: owned ? "puzzlepiece.extension.fill" : "lock.fill", tint: owned ? Theme.accent : Theme.textDim, title: item.name,
                              subtitle: subtitle(item), isOn: Binding(get: { owned && !choice.disabledDLC.contains(item.appid) },
                                                                      set: { if owned { store.setDLC(game.id, app: item.appid, enabled: $0) } }))
                }
                Text("DLC you own is installed with the game, as in Steam. Turning one off keeps files already on the device; it only stops new ones from being downloaded.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            }
        }
    }

    private func subtitle(_ item: SteamDLC) -> String {
        let size = item.diskBytes > 0 ? SteamGameTile.size(item.diskBytes) : nil
        switch item.owned {
        case true?: return ["Owned", size].compactMap { $0 }.joined(separator: " \u{00B7} ")
        case false?: return "Not owned on this account"
        default: return "Ownership not known"
        }
    }

    // MARK: Apply

    @ViewBuilder private var applyGroup: some View {
        SettingsGroup {
            ActionRow(id: "sv-apply", symbol: "arrow.down.circle.fill", title: installed ? "Download changes" : "Install with these choices", subtitle: installed
                      ? "Fetches only what differs from the files on this device." : nil, prominent: true, action: apply)
        }
    }

    private func load() async {
        loading = true; failure = nil
        do { details = try await store.details(game.id) } catch { failure = SteamSignIn.message(error) }
        loading = false
    }
}
