// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Adding a game: three clear ways in, then the games already sitting in the app, found for you. Replaces the old single long list of Windows paths.
struct AddGameFlow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onSteam: () -> Void = {}
    var onEpic: () -> Void = {}
    var onGog: () -> Void = {}
    var onItch: () -> Void = {}
    var onAmazon: () -> Void = {}
    var onInstaller: () -> Void = {}

    @State private var discovered: [DiscoveredGame] = []
    @State private var scanning = true
    @State private var query = ""
    @State private var pickFolder = false
    @State private var importing: URL?
    @State private var choosing: Choice?
    @State private var manual = ""
    @State private var showManual = false

    /// A game whose program the person must pick (more than one plausible program).
    struct Choice: Identifiable, Hashable {
        let name: String
        let programs: [GameProgram]
        var id: String { name + (programs.first?.id ?? "") }
        static func == (l: Choice, r: Choice) -> Bool { l.id == r.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private var inLibrary: Set<String> { Set(model.games.map { $0.exe.lowercased() }) }
    private var available: [DiscoveredGame] {
        let library = inLibrary
        let games = discovered.filter { game in !game.programs.contains { library.contains($0.file.path.lowercased()) } }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? games : games.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    @State private var scope = FocusScope()
    @State private var notice: String?

    var body: some View {
        KitSheet(title: choosing?.name ?? "Add a game", closeTitle: choosing == nil ? "Cancel" : "Back", closeSymbol: choosing == nil ? "xmark" : "chevron.left",
                 scope: scope, defaultFocus: "add-folder", close: { if choosing != nil { choosing = nil } else { dismiss() } }) {
            Group {
                if let choice = choosing { ProgramChooserView(name: choice.name, programs: choice.programs) { program in add(program, as: choice.name) } }
                else { start }
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .sheet(isPresented: $pickFolder) {
            FolderPickerSheet(onPick: { url in
                LogStore.shared.log("[import] folder picked: \(url.lastPathComponent)")
                pickFolder = false; importing = url
            }, onCancel: { LogStore.shared.log("[import] the folder picker was closed without a folder"); pickFolder = false })
        }
        .sheet(item: Binding(get: { importing.map(ImportTarget.init) }, set: { if $0 == nil { importing = nil } })) { target in
            ImportGameView(source: target.url, onCopied: { destination in importing = nil; afterImport(destination, name: target.url.lastPathComponent) }, onCancel: { importing = nil })
                .environmentObject(model).interactiveDismissDisabled()
        }
        .task { await scan() }
        .localGuide("addgame")
        .presentationSizing(.page)
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "How do you want to add it?") {
                ActionRow(id: "add-folder", symbol: "folder.badge.plus", title: "Import a game folder", subtitle: "In Files, open the game's folder, then tap Open",
                          info: "In Files, tap folders until you are inside the game's folder (the one with its .exe), then tap Open at the top right. Tapping a folder only goes into it; Open chooses the folder you are in. It is copied into the app, so it needs that much free space.") { pickFolder = true }
                ActionRow(id: "add-steam", symbol: "arrow.down.circle.fill", tint: .blue, title: "Download from Steam", subtitle: "Games you own",
                          info: "Games you own on Steam, installed straight into the app.") { dismiss(); onSteam() }
                ActionRow(id: "add-epic", symbol: "arrow.down.circle.fill", tint: .indigo, title: "Download from Epic Games", subtitle: "Games you own",
                          info: "Games you own on Epic Games, installed straight into the app. You sign in on Epic's own page.") { dismiss(); onEpic() }
                ActionRow(id: "add-gog", symbol: "arrow.down.circle.fill", tint: .purple, title: "Download from GOG", subtitle: "Games you own",
                          info: "Games you own on GOG, installed straight into the app. You sign in on GOG's own page.") { dismiss(); onGog() }
                ActionRow(id: "add-itch", symbol: "arrow.down.circle.fill", tint: .red, title: "Download from itch.io", subtitle: "Games you own or claimed",
                          info: "Games you bought, claimed or collected on itch.io, installed straight into the app. You sign in with your own API key.") { dismiss(); onItch() }
                ActionRow(id: "add-amazon", symbol: "arrow.down.circle.fill", tint: .orange, title: "Download from Amazon Games", subtitle: "Games you own or claimed",
                          info: "Games you bought on Amazon or claimed with Prime Gaming, installed straight into the app. You sign in on Amazon's own page.") { dismiss(); onAmazon() }
                ActionRow(id: "add-installer", symbol: "shippingbox.fill", tint: .orange, title: "Run a Windows installer", subtitle: "A disc or a setup file",
                          info: "For games from a disc or a setup file you already have. Pick the setup file, run it, then add what it installed.") { dismiss(); onInstaller() }
            }
            if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
            onDevice
            advanced
        }
    }

    // MARK: Games already in the app

    @ViewBuilder private var onDevice: some View {
        SettingsGroup(title: "Already in the app") {
            if scanning {
                HStack(spacing: 10) { ProgressView().tint(Theme.accent); Text("Looking for games\u{2026}").foregroundStyle(Theme.textDim) }.padding(.horizontal, 6)
            } else if discovered.isEmpty || available.isEmpty && query.isEmpty {
                Text(discovered.isEmpty ? "No games found yet. Files you import, download or install show up here." : "Everything found is already in your library.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
            } else {
                if discovered.count > 6 { TextFieldRow(id: "add-search", symbol: "magnifyingglass", title: "Search", placeholder: "Game name", text: $query) }
                ForEach(available) { game in
                    RowBase(id: "add-d-\(game.id)", symbol: "gamecontroller.fill", title: game.name, subtitle: game.best.map { "Starts \($0.fileName)" } ?? "Choose a program", action: { choose(game) }) {
                        Text("Add").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(Theme.onAccent).padding(.horizontal, 12).padding(.vertical, 5).background(Theme.accentGradient, in: Capsule())
                    }
                }
                if available.isEmpty { Text("No match for \u{201C}\(query)\u{201D}.").foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
            }
        }
    }

    @ViewBuilder private var advanced: some View {
        SettingsGroup {
            ActionRow(id: "add-path-toggle", symbol: "terminal.fill", title: "Add by path", detail: showManual ? "Hide" : nil, chevron: !showManual) { showManual.toggle() }
            if showManual {
                TextFieldRow(id: "add-path", symbol: "pencil", title: "Program", placeholder: #"C:\Games\Foo\foo.exe"#, monospaced: true, text: $manual)
                PillButton(id: "add-path-go", title: "Add", symbol: "plus", style: .primary, enabled: !manual.isEmpty) { model.add(exe: manual); dismiss() }
            }
        }
    }

    // MARK: Actions

    private func scan() async {
        let drive = AppModel.driveC
        let found = await Task.detached(priority: .userInitiated) { GameDiscovery.discover(GameDiscovery.scanDrive(drive)) }.value
        discovered = found; scanning = false
    }

    /// One tap adds the game when its program is clear; otherwise the person confirms which one.
    private func choose(_ game: DiscoveredGame) {
        let plausible = game.programs.filter { $0.kind != .tool }
        if let best = game.best, plausible.count == 1 || (plausible.count > 1 && best.score - plausible[1].score >= 20) {
            add(best, as: game.name)
        } else {
            choosing = Choice(name: game.name, programs: game.programs)
        }
    }

    private func add(_ program: GameProgram, as name: String) {
        model.add(exe: program.file.path, name: name)
        dismiss()
    }

    private func afterImport(_ destination: URL, name: String) {
        Task {
            let drive = AppModel.driveC
            let found = await Task.detached { GameDiscovery.scanDrive(drive, under: destination) }.value
            let games = GameDiscovery.discover(found)
            let programs = games.flatMap(\.programs).sorted { $0.score > $1.score }
            let plausible = programs.filter { $0.kind != .tool }
            if let best = plausible.first, plausible.count == 1 || best.score - plausible[1].score >= 20 { add(best, as: name) }
            else if programs.isEmpty { LogStore.shared.log("[import] \(name) was copied but has no program (.exe)", level: .error); notice = "The folder was copied, but there is no program (.exe) inside. You can add one by path." }
            else { choosing = Choice(name: name, programs: programs) }
        }
    }
}

private struct ImportTarget: Identifiable { let url: URL; var id: URL { url } }

private struct DiscoveredRow: View {
    let game: DiscoveredGame
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: "gamecontroller.fill", tint: Theme.accent, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name).foregroundStyle(Theme.text).font(.body.weight(.medium)).lineLimit(1)
                    Text(game.best.map { "Starts \($0.fileName)" } ?? "Choose a program").font(.footnote).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Add").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Picking the program

/// "This is the one": the most likely program, big and clear, with the rest a tap away.
struct ProgramChooserView: View {
    let name: String
    let programs: [GameProgram]
    /// The big button's wording; "Add \u{201C}name\u{201D}" when nil (adding a game), something else when this picks a replacement program.
    var actionTitle: String?
    let onPick: (GameProgram) -> Void
    @State private var showTools = false
    @State private var query = ""
    @State private var bits: Int?

    private var best: GameProgram? { programs.first { $0.kind != .tool } ?? programs.first }
    private var others: [GameProgram] {
        let rest = programs.filter { $0.id != best?.id && (showTools || $0.kind != .tool) }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? rest : rest.filter { $0.relative.localizedCaseInsensitiveContains(q) }
    }
    private var hiddenTools: Int { programs.filter { $0.id != best?.id && $0.kind == .tool }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let best {
                SettingsGroup(title: best.kind == .tool ? "Only tools were found" : "Most likely") {
                    RowBase(id: "pc-best", symbol: "gamecontroller.fill", title: best.fileName, subtitle: best.relative != best.fileName ? best.relative : nil, action: { onPick(best) }) {
                        HStack(spacing: 6) {
                            Text(ByteCountFormatter.string(fromByteCount: best.file.size, countStyle: .file)).font(.footnote).foregroundStyle(Theme.textDim)
                            if let bits { Text("\(bits)-bit").font(.footnote).foregroundStyle(Theme.textDim) }
                        }
                    }
                    PillButton(id: "pc-add", title: actionTitle ?? "Add \u{201C}\(name)\u{201D}", symbol: actionTitle == nil ? "plus" : "checkmark", style: .primary) { onPick(best) }
                }
                .task { bits = await Task.detached { AppModel.peBits(windowsPath: best.file.path) }.value }
            }
            if programs.count > 1 {
                SettingsGroup(title: "Not the right one?") {
                    if programs.count > 12 { TextFieldRow(id: "pc-search", symbol: "magnifyingglass", title: "Search", placeholder: "Program name", text: $query) }
                    ForEach(others) { program in
                        RowBase(id: "pc-\(program.id)", title: program.fileName, subtitle: program.relative != program.fileName ? program.relative : nil, action: { onPick(program) }) {
                            Text(ByteCountFormatter.string(fromByteCount: program.file.size, countStyle: .file)).font(.footnote).foregroundStyle(Theme.textDim)
                        }
                    }
                    if others.isEmpty { Text(query.isEmpty ? "Nothing else was found." : "No match.").foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
                    if hiddenTools > 0 || showTools { ToggleRow(id: "pc-tools", symbol: "wrench.and.screwdriver.fill", title: "Show installers and tools (\(hiddenTools))", isOn: $showTools) }
                }
            }
        }
    }
}

// MARK: - Copying a folder in

/// Copies the picked folder into the app with a progress bar, then reports where it went.
struct ImportGameView: View {
    @EnvironmentObject var model: AppModel
    let source: URL
    let onCopied: (URL) -> Void
    let onCancel: () -> Void
    @State private var importer = GameImporter()
    @State private var progress: GameImporter.Progress?
    @State private var error: String?
    @State private var started = false

    @State private var scope = FocusScope()

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            IconTile(symbol: "folder.fill", size: 64)
            VStack(spacing: 6) {
                Text(source.lastPathComponent).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                Text(error == nil ? "Copying into the app" : "Couldn't import it").font(.subheadline).foregroundStyle(Theme.textDim)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(Theme.bad).multilineTextAlignment(.center)
                PillButton(id: "imp-close", title: "Close", symbol: "xmark", style: .primary) { onCancel() }
            } else {
                VStack(spacing: 8) {
                    if let p = progress, p.total > 0 {
                        ProgressView(value: Double(p.copied), total: Double(max(p.total, 1))).tint(Theme.accent)
                        HStack {
                            Text("\(ByteCountFormatter.string(fromByteCount: p.copied, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: p.total, countStyle: .file))")
                            Spacer()
                            Text("\(Int(Double(p.copied) / Double(max(p.total, 1)) * 100))%")
                        }
                        .font(.footnote.monospacedDigit()).foregroundStyle(Theme.textDim)
                        Text(p.file).font(.caption2.monospaced()).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                    } else { ProgressView("Reading the folder\u{2026}").tint(Theme.accent) }
                }
                .frame(maxWidth: 420)
                PillButton(id: "imp-cancel", title: "Cancel", symbol: "xmark") { importer.cancel() }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackdrop(animated: false).ignoresSafeArea())
        .navScope(scope)
        .onAppear { scope.onBack = { if error != nil { onCancel() } else { importer.cancel() } }; scope.defaultFocus = "imp-cancel"; scope.focused = "imp-cancel" }
        .onChange(of: error) { _, e in if e != nil { scope.focused = "imp-close" } }
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
        .task {
            guard !started else { return }
            started = true
            LogStore.shared.log("[import] copying \(source.lastPathComponent) into the app")
            let importer = importer, source = source
            do {
                let destination = try await Task.detached(priority: .userInitiated) {
                    try importer.run(from: source) { p in Task { @MainActor in self.progress = p } }
                }.value
                LogStore.shared.log("[import] copied \(source.lastPathComponent)")
                onCopied(destination)
            } catch let e as GameImporter.ImportError {
                if case .cancelled = e { LogStore.shared.log("[import] cancelled"); onCancel() }
                else { LogStore.shared.log("[import] failed: \(e.localizedDescription)", level: .error); error = e.localizedDescription }
            } catch { LogStore.shared.log("[import] failed: \(error.localizedDescription)", level: .error); self.error = error.localizedDescription }
        }
    }
}
