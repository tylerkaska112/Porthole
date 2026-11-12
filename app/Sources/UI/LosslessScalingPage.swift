// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Stores > Software > Lossless Scaling: the licence check and download for Lossless Scaling frame generation. It shows whether the signed-in Steam account owns Lossless Scaling, how long the stored
/// proof stays valid, downloads the file from Steam and keeps it sealed (LosslessLicence.swift says how and why).
struct LosslessScalingPage: View {
    @Environment(AppRouter.self) private var router
    @ObservedObject private var ls = LosslessScaling.shared
    @ObservedObject private var steam = SteamStore.shared

    private func back() { router.storesSelection = .software }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PillButton(id: "ls-back", title: "Software", symbol: "chevron.left", action: back)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 8)
            FocusScroll {
                PageScaffold(title: "Lossless Scaling", symbol: "wand.and.rays",
                             subtitle: "Frame generation from Lossless Scaling works for people who bought it on Steam. This page checks your purchase and downloads your copy.") {
                    yourCopy
                    if let message = ls.message { Text(message).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
                }
                .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
        }
        .onNavBack { back(); return true }
        .task {
            ls.reload()
            // An old proof is renewed on the way in, so that the page shows what is true now (offline, it simply stays as it was).
            if ls.signedIn, ls.receipt == nil || ls.status != nil && !isFresh { await ls.verify() }
        }
    }

    private var isFresh: Bool { if let r = ls.receipt { return Date().timeIntervalSince(r.verifiedAt) < 86_400 } else { return false } }

    // MARK: Rows

    private var yourCopy: some View {
        SettingsGroup(title: "Your copy", note: "Needs Lossless Scaling on your own Steam account. Porthole never ships it and takes it from Steam only.") {
            ValueRow(id: "ls-account", symbol: "person.crop.circle", title: "Steam account", value: ls.signedIn ? (ls.accountName ?? "Signed in") : "Not signed in")
            ValueRow(id: "ls-owned", symbol: "cart.fill", title: "Bought on this account", value: ownedText, statusColor: ownedColor)
            ValueRow(id: "ls-proof", symbol: "checkmark.seal.fill", title: "Proof kept on this device", value: proofText, statusColor: proofColor)
            ValueRow(id: "ls-file", symbol: "lock.doc.fill", title: "The file", value: ls.fileBytes.map { "Sealed on this device (\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)))" } ?? "Not downloaded")
            if let busy = ls.busy {
                VStack(alignment: .leading, spacing: 6) {
                    Text(busy).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textDim)
                    if let p = ls.progress { ProgressView(value: p) } else { ProgressView() }
                }.padding(.horizontal, 6)
            }
            if !ls.signedIn {
                ActionRow(id: "ls-signin", symbol: "person.badge.key.fill", title: "Sign in to Steam", subtitle: "In Stores > Steam", prominent: true) { router.openSteam() }
            } else {
                ActionRow(id: "ls-check", symbol: "arrow.clockwise", title: "Check my Steam purchase", subtitle: "Asks Steam whether this account has an active licence",
                          chevron: false) { Task { await ls.verify() } }
                if !ls.installed {
                    ActionRow(id: "ls-download", symbol: "arrow.down.circle.fill", title: "Download from Steam", subtitle: "Only the one file is kept, sealed",
                              chevron: false, prominent: ls.owned == true) { Task { await ls.download() } }
                }
            }
            if ls.installed || ls.receipt != nil {
                ActionRow(id: "ls-remove", symbol: "trash", title: "Remove from this device", subtitle: "Deletes the sealed file and the proof", destructive: true, chevron: false) { ls.remove() }
            }
        }
    }

    // MARK: Words

    private var ownedText: String {
        switch ls.owned {
        case true?: "Yes, Steam lists it"
        case false?: "No, not on this account"
        case nil: ls.receipt != nil ? "Checked earlier" : "Not checked yet"
        }
    }
    private var ownedColor: Color? { ls.owned == true ? Theme.good : (ls.owned == false ? Theme.warn : nil) }

    private var proofText: String {
        guard ls.receipt != nil, let status = ls.status else { return "None" }
        switch status {
        case .valid(let days): return days <= 0 ? "Valid until the next check" : "Valid for \(days) more day\(days == 1 ? "" : "s") without going online"
        case .expired: return "Out of date: needs an online check"
        case .tampered: return "Does not verify: remove it and check again"
        case .otherAccount: return "Belongs to another Steam account"
        }
    }
    private var proofColor: Color? {
        guard ls.receipt != nil, let status = ls.status else { return nil }
        if case .valid = status { return Theme.good }
        return Theme.warn
    }
}
