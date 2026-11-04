// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Settings > Saves: one zip of every Windows user's saves and settings to keep in Files or iCloud Drive, and the way back.
struct SavesPage: View {
    @State private var busy = false
    @State private var message: String?
    @State private var shareURL: URL?
    @State private var picking = false
    @State private var pendingRestore: URL?
    @State private var autoOn = AutoBackup.enabled()
    @State private var autoEntries: [AutoBackup.Entry] = []
    @State private var autoMessage: String?
    @State private var confirmDeleteAuto = false

    var body: some View {
        PageScaffold(title: "Saves", symbol: "externaldrive.badge.icloud", subtitle: "Backups of your games' saves") {
            automaticGroup
            SettingsGroup(title: "Backup") {
                ActionRow(id: "sv-backup", symbol: "square.and.arrow.up", title: "Back up saves", subtitle: busy ? "Working\u{2026}" : "Every game's saves and settings in one zip",
                          info: "One zip of every Windows user's Documents, Saved Games and AppData (caches and Steam's own files left out), to keep in Files or iCloud Drive. A prefix reset or a reinstall takes saves with it; a backup does not.",
                          chevron: false, action: backup)
                ActionRow(id: "sv-restore", symbol: "arrow.uturn.backward.circle", title: "Restore saves from a backup\u{2026}", chevron: false) { picking = true }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            }
            Text("Restoring puts the backup's files back and overwrites files with the same names in C:\\users. Games' own folders are not part of a backup.")
                .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
        }
        // The zip is a copy made for sharing: removed once the share sheet closes.
        .sheet(item: Binding(get: { shareURL.map { SharedBackup(url: $0) } }, set: {
            if $0 == nil { if let url = shareURL { try? FileManager.default.removeItem(at: url) }; shareURL = nil }
        })) { ActivityView(items: [$0.url]) }
        .sheet(isPresented: $picking) {
            FilePickerSheet(onPick: { urls in picking = false; if let url = urls.first { pendingRestore = url } }, onCancel: { picking = false })
        }
        .confirm("Restore saves from \(pendingRestore?.lastPathComponent ?? "the backup")?", message: "Files with the same names in C:\\users are overwritten.", confirmTitle: "Restore", destructive: true,
                 isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) { restore() }
    }

    private var automaticGroup: some View {
        SettingsGroup(title: "Automatic backups") {
            ToggleRow(id: "sv-auto", symbol: "clock.arrow.circlepath", title: "Back up after each game",
                      info: "When a game ends, your saves and settings are zipped into Files > Porthole > Saves backups. The newest five are kept, and nothing is written when nothing has changed, when the saves are over 150 MB, or when the phone is nearly out of space.",
                      isOn: Binding(get: { autoOn }, set: { autoOn = $0; AutoBackup.setEnabled($0) }))
            ForEach(autoEntries) { entry in
                ActionRow(id: "sv-a-\(entry.id)", symbol: "archivebox.fill", title: entry.date.formatted(date: .abbreviated, time: .shortened),
                          subtitle: ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file), detail: "Restore", chevron: false) { pendingRestore = entry.url }
            }
            if autoEntries.isEmpty { Text(autoOn ? "No automatic backups yet. The first one is made when a game ends." : "Automatic backups are off.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            ActionRow(id: "sv-auto-now", symbol: "arrow.clockwise.circle", title: "Back up now", chevron: false) { runAutomatic() }
            if !autoEntries.isEmpty { ActionRow(id: "sv-auto-del", symbol: "trash", title: "Delete the automatic backups", destructive: true, chevron: false) { confirmDeleteAuto = true } }
            if let autoMessage { Text(autoMessage).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
        }
        .onAppear { autoEntries = AutoBackup.entries() }
        .confirm("Delete the automatic backups?", message: "This removes the backups in Saves backups. Your saves themselves are not touched.", confirmTitle: "Delete", destructive: true, isPresented: $confirmDeleteAuto) {
            AutoBackup.deleteAll(); autoEntries = []; autoMessage = "Deleted."
        }
    }

    private func runAutomatic() {
        guard !busy else { return }
        busy = true; autoMessage = "Backing up\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = AutoBackup.run(force: true)
            DispatchQueue.main.async { busy = false; autoMessage = outcome.text; autoEntries = AutoBackup.entries() }
        }
    }

    private func backup() {
        guard !busy else { return }
        busy = true; message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Swift.Result { try SaveBackup.backup() }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let b):
                    message = "\(b.files) files, \(ByteCountFormatter.string(fromByteCount: Int64(b.bytes), countStyle: .file))" + (b.leftOut > 0 ? "; \(b.leftOut) very large files left out" : "")
                    shareURL = b.url
                case .failure(let e): message = e.localizedDescription
                }
            }
        }
    }

    private func restore() {
        guard let url = pendingRestore, !busy else { return }
        pendingRestore = nil; busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Swift.Result { try SaveBackup.restore(from: url) }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let n): message = "\(n) files restored."
                case .failure(let e): message = e.localizedDescription
                }
            }
        }
    }
}

private struct SharedBackup: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
