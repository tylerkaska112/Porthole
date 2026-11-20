// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// One entry of the quick layout switch (the in-game menu's Layout card): the game's own default controls, or one of its sets that has a touch layout.
struct LayoutChoice: Identifiable, Equatable {
    /// "default", or the set's id.
    let id: String
    let title: String
    let selected: Bool
    /// The set it stands for (nil: the default controls).
    let setID: UUID?
}

/// What a game's page and the in-game menu do with a game's touch layouts. A layout of the game's own is always a bind set (see BindSet), so nothing ever overwrites the default controls or
/// another layout: choosing a starter or editing the default makes a new set and uses it, and the old ones stay to be switched back to.
enum GameLayouts {
    /// A name no other set of the game has ("Action", then "Action 2", ...).
    static func uniqueName(_ base: String, in sets: [BindSet]) -> String {
        guard sets.contains(where: { $0.name == base }) else { return base }
        var n = 2
        while sets.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }

    /// A new set holding `layout`, in use from now on. Returns its id.
    @discardableResult
    static func addSet(_ layout: TouchLayout, named base: String, to g: inout Game) -> UUID {
        let set = BindSet(name: uniqueName(base, in: g.bindSets ?? []), touch: layout.sanitized())
        g.bindSets = (g.bindSets ?? []) + [set]
        g.activeBindSetID = set.id
        g.ownControls = true
        return set.id
    }

    /// An edited layout: kept in the set in use; a game that follows the default controls gets a set of its own for it (the default stays as it was).
    static func save(_ layout: TouchLayout, into g: inout Game, named base: String) {
        if let active = g.activeBindSetID, var sets = g.bindSets, let i = sets.firstIndex(where: { $0.id == active }) {
            sets[i].touch = layout.sanitized(); sets[i].updated = Date(); g.bindSets = sets
            return
        }
        addSet(layout, named: base, to: &g)
    }

    /// The default controls (when the game follows them or a set without a touch layout is in use), then every set that has a touch layout.
    static func choices(for g: Game) -> [LayoutChoice] {
        let sets = (g.bindSets ?? []).filter { $0.touch != nil }
        let activeTouchSet = g.activeBindSetID.flatMap { id in sets.first { $0.id == id } }
        var out = [LayoutChoice(id: "default", title: "Default", selected: activeTouchSet == nil, setID: nil)]
        out += sets.map { LayoutChoice(id: $0.id.uuidString, title: $0.name, selected: $0.id == activeTouchSet?.id, setID: $0.id) }
        return out
    }
}
