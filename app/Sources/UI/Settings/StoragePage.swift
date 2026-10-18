// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Settings > Storage: what is using the space on the device. Free space, every game with its size (biggest first) and a way to delete a store game's files,
/// and the temporary files the app can clear.
struct StoragePage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var steam = SteamStore.shared
    @ObservedObject private var epic = EpicInstaller.shared
    @State private var sizes: [UUID: Int64] = [:]
    @State private var scanning = false
    @State private var cacheBytes: Int64 = 0
    @State private var deleting: Game?
    @State private var confirmClear = false
    @State private var note: String?

    private var capacity: (free: Int64, total: Int64) {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }
    private func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private var rows: [Game] {
        model.games.sorted { (sizes[$0.id] ?? -1) > (sizes[$1.id] ?? -1) }
    }
    private var gamesTotal: Int64 { sizes.values.reduce(0, +) }

    private func source(_ game: Game) -> String {
        if game.store == .epic { return "Epic Games" }
        if game.store == .gog { return "GOG" }
        if game.store == .itch { return "itch.io" }
        if game.store == .amazon { return "Amazon Games" }
        if game.store == .steam { return "Steam" }
        return "Imported"
    }
    private func deletable(_ game: Game) -> Bool { game.store != nil }

    var body: some View {
        PageScaffold(title: "Storage", symbol: "internaldrive.fill") {
            SettingsGroup(title: "This device") {
                let c = capacity
                ValueRow(id: "sto-free", symbol: "externaldrive.fill", title: "Free space", value: c.total > 0 ? "\(text(c.free)) of \(text(c.total))" : text(c.free))
                ValueRow(id: "sto-games", symbol: "gamecontroller.fill", title: "Used by your games", value: scanning && sizes.isEmpty ? "Measuring\u{2026}" : text(gamesTotal))
            }
            SettingsGroup(title: "Games") {
                if model.games.isEmpty {
                    Text("No games yet. Downloads from the Stores tab and imported games show up here with their size.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                }
                ForEach(rows) { game in
                    let size = sizes[game.id].map(text) ?? (scanning ? "Measuring\u{2026}" : "Unknown")
                    if deletable(game) {
                        ActionRow(id: "sto-\(game.id)", symbol: game.store == .epic ? "bag.fill" : "arrow.down.circle.fill", tint: game.store == .epic ? .indigo : .blue,
                                  title: game.name, subtitle: "\(source(game)) \u{00B7} tap to delete its files", detail: size, chevron: false) { deleting = game }
                    } else {
                        ValueRow(id: "sto-\(game.id)", symbol: "folder.fill", title: game.name, value: size)
                    }
                }
                if model.games.contains(where: { !deletable($0) }) {
                    Text("Imported games keep their files until you remove them in the Files app; \u{201C}Remove from library\u{201D} on a game's page only takes it off the shelf.")
                        .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                }
            }
            SettingsGroup(title: "Temporary files") {
                ValueRow(id: "sto-cache", symbol: "tray.full.fill", title: "Cached pictures and downloaded updates", value: text(cacheBytes))
                ActionRow(id: "sto-clear", symbol: "trash", title: "Clear temporary files", destructive: true, chevron: false) { confirmClear = true }
                if let note { Text(note).font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            }
        }
        .task { await scan() }
        .confirm("Delete \(deleting?.name ?? "")'s files?", message: "This frees \(deleting.flatMap { sizes[$0.id] }.map(text) ?? "the space") on the device. You can download it again from the Stores tab.",
                 confirmTitle: "Delete files", destructive: true, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let game = deleting { delete(game) }
            deleting = nil
        }
        .confirm("Clear temporary files?", message: "Pictures are fetched again when they are needed, and an update that was downloaded is downloaded again. Your games and saves are not touched.",
                 confirmTitle: "Clear", destructive: true, isPresented: $confirmClear) { clearCache() }
    }

    // MARK: Work

    private func scan() async {
        scanning = true
        cacheBytes = await Self.cacheSize()
        for game in model.games {
            if let bytes = await GameInfo.folderBytes(for: game) { sizes[game.id] = bytes }
        }
        scanning = false
    }

    private func delete(_ game: Game) {
        if let appName = game.epicAppName { epic.uninstall(appName) }
        else if let id = game.gogID { GogInstaller.shared.uninstall(id) }
        else if let id = game.itchID { ItchInstaller.shared.uninstall(id) }
        else if let id = game.amazonID { AmazonInstaller.shared.uninstall(id) }
        else {
            if let id = game.dockAppID, let owned = steam.owned.first(where: { $0.id == id }) { steam.uninstall(owned) }
            model.remove(game)
        }
        sizes[game.id] = nil
        Task { try? await Task.sleep(for: .seconds(2)); await scan() }
    }

    private func clearCache() {
        if UpdateService.current?.pipeline.isBusy == true { note = "An update is running; try again when it has finished."; return }
        Task {
            await Task.detached(priority: .utility) {
                let fm = FileManager.default
                if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
                   let items = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
                    for item in items { try? fm.removeItem(at: item) }
                }
            }.value
            cacheBytes = await Self.cacheSize()
            note = "Cleared."
        }
    }

    private static func cacheSize() async -> Int64 {
        await Task.detached(priority: .utility) { () -> Int64 in
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                  let walker = FileManager.default.enumerator(at: caches, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
            var total: Int64 = 0
            for case let url as URL in walker {
                if let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Int64(v.totalFileAllocatedSize ?? 0) }
            }
            return total
        }.value
    }
}
