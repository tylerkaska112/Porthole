// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The top of a game's Controls page: what is in use right now, drawn, and the three things people do next: try it, edit it, change it. It replaces hunting through the rows below for
/// "which layout is this game using?". A line about the layout (buttons on top of each other, or too small to hit) and a popular shared layout appear only when there is something to say.
struct GameControlsCard: View {
    let gameID: UUID
    @EnvironmentObject var model: AppModel
    @State private var sandbox: Request?
    @State private var choosing = false
    @State private var browsing = false
    @State private var popular: SharedBind?
    /// The name of a layout just added here: a line says it is in use and suggests trying it, for a few seconds.
    @State private var justMade: String?

    private struct Request: Identifiable { let id = UUID(); let edit: Bool }
    private var game: Game? { model.games.first { $0.id == gameID } }

    /// What the screen in landscape has to draw on, near enough for the layout check (the safe areas are about this much).
    private static var field: CGSize {
        let b = UIScreen.main.bounds
        return CGSize(width: max(b.width, b.height) - 120, height: min(b.width, b.height) - 40)
    }

    var body: some View {
        if let g = game {
            let layout = g.effectiveTouchLayout
            SettingsGroup(title: "In use now") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 16) {
                        if let layout {
                            LayoutPreview(layout: layout, caption: nil).frame(width: 190)
                        } else {
                            Image(systemName: "gamecontroller.fill").font(.system(size: 34)).foregroundStyle(Theme.accent).frame(width: 190, height: 107)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(describe(g).title).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                            Text(describe(g).detail).font(.system(size: 13)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    if let justMade {
                        Label("\(justMade) is in use now. Try it to feel how it plays.", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.good)
                    }
                    HStack(spacing: 10) {
                        PillButton(id: "gc-try", title: "Try it", symbol: "hand.tap.fill", style: .primary) { sandbox = Request(edit: false) }
                        if layout != nil {
                            PillButton(id: "gc-edit", title: "Edit", symbol: "pencil") { sandbox = Request(edit: true) }
                            PillButton(id: "gc-change", title: "Change layout", symbol: "rectangle.on.rectangle") { choosing = true }
                        }
                    }
                    if let layout, let line = LayoutCheck.run(layout, field: Self.field, scale: TouchButtonSize.factor(setting: UserDefaults.standard.string(forKey: TouchButtonSize.key),
                                                                                                                         isPad: UIDevice.current.userInterfaceIdiom == .pad),
                                                              mirrored: TouchHandedness.leftHanded).summary {
                        Button { sandbox = Request(edit: true) } label: {
                            Label(line + " Tap to fix it in the editor.", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.warn).multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .focusTarget("gc-check", radius: 10, scale: 1.0) { sandbox = Request(edit: true) }
                    }
                    if let popular {
                        Button { browsing = true } label: {
                            Label("Popular with other players: \(popular.displayName) (\(popular.downloads) \(popular.downloads == 1 ? "download" : "downloads"))",
                                  systemImage: "person.2.fill")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textDim).multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .focusTarget("gc-popular", radius: 10, scale: 1.0) { browsing = true }
                    }
                }
                .padding(14)
            }
            .fullScreenCover(item: $sandbox) { request in
                if let layout {
                    ControlsSandboxScreen(layout: layout, title: describe(g).title, startEditing: request.edit) { edited in
                        guard let now = game else { return }
                        model.update(now) { GameLayouts.save(edited, into: &$0, named: "My layout") }
                    }
                } else {
                    ControlsSandboxScreen(layout: TouchLayout(), title: "On-screen controller", pad: SandboxPad.current) { _ in }
                }
            }
            .sheet(isPresented: $choosing) {
                StarterLayoutPicker(title: "Change layout") { picked, title in
                    guard let now = game else { return }
                    model.update(now) { GameLayouts.addSet(picked, named: title, to: &$0) }
                    justMade = title
                }.preferredColorScheme(Theme.scheme)
            }
            .sheet(isPresented: $browsing) { SharedBindsBrowser(gameID: gameID).environmentObject(model).preferredColorScheme(Theme.scheme) }
            .task(id: g.id) { await loadPopular(g) }
            .task(id: justMade) { if justMade != nil { try? await Task.sleep(nanoseconds: 9_000_000_000); justMade = nil } }
        }
    }

    /// The name and one line for what is in use.
    private func describe(_ g: Game) -> (title: String, detail: String) {
        if g.effectiveTouchLayout == nil { return ("On-screen game controller", "An Xbox-style controller drawn on the screen. How it looks and how big it is are in the game's menu, under Controls.") }
        if let set = g.activeBindSet, set.touch != nil { return (set.name, "A layout of your own for this game. Your default controls and your other layouts are kept.") }
        let kind = DefaultControls.current.kind.title
        return (kind, "Your default controls. Editing makes a copy just for this game; the default stays as it is.")
    }

    /// The most popular touch layout other players shared for this game, if the sharing service has one (quietly nothing when it does not).
    private func loadPopular(_ g: Game) async {
        popular = nil
        let store = BindsShareStore.shared
        guard store.available, let ref = await store.gameRef(for: g), let items = try? await store.list(gameID: ref.id, sort: "downloads") else { return }
        popular = items.filter(\.hasTouch).first
    }
}
