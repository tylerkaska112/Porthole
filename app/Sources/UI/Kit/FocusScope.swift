// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import CoreGraphics
import Observation

/// The set of focus targets on one layer of the interface (the main frame, or something on top of it such as a pop-up).
@MainActor @Observable
final class FocusScope {
    struct Entry { var frame: CGRect; var action: (() -> Void)?; var secondary: (() -> Void)?; var adjust: ((Int) -> Void)?; var label: String? = nil; var secondaryLabel: String? = nil; var engageToAdjust = false }

    /// The target that has the glow.
    var focused: AnyHashable?
    /// Set when focus moved by D-pad: scroll views bring this target into view.
    private(set) var scrollRequest: AnyHashable?
    private(set) var scrollTick = 0
    /// Bumped when the focused target's labels change (a download starts, so X reads Pause instead of Download): the hints bar redraws.
    private(set) var hintsTick = 0
    /// A slider A has gone "into": while it is, Left / Right change its value; otherwise they just move the glow (nothing changes by passing over it).
    private(set) var engaged: AnyHashable?
    /// Whether the person has driven this layer with the controller since it last started at its set place.
    @ObservationIgnored private var moved = false
    @ObservationIgnored private(set) var entries: [AnyHashable: Entry] = [:]
    /// Where to start when nothing has focus yet.
    @ObservationIgnored var defaultFocus: AnyHashable?
    @ObservationIgnored var onBack: (() -> Void)?
    @ObservationIgnored var onMenu: (() -> Void)?
    @ObservationIgnored var onSection: ((Int) -> Void)?       // -1 previous, +1 next
    @ObservationIgnored var onTertiary: (() -> Void)?
    /// What X does when the focused target has nothing of its own for it.
    @ObservationIgnored var onSecondary: (() -> Void)?
    /// What the bar of controller hints calls Y and Menu on this layer (nil: "More" / "Menu"); the hint only shows when the matching handler is set.
    @ObservationIgnored var tertiaryLabel: String?
    @ObservationIgnored var menuLabel: String?
    @ObservationIgnored var secondaryLabel: String?
    /// The entry that has the glow now (what the hints bar describes). Reading it from a view also tracks `focused`.
    var focusedEntry: Entry? { focused.flatMap { entries[$0] } }
    var hasSections: Bool { onSection != nil }
    var hasMenu: Bool { onMenu != nil }
    var hasTertiary: Bool { onTertiary != nil }
    var hasSecondaryFallback: Bool { onSecondary != nil }
    /// How long a vanished target is given to come back (a redraw removes and re-adds it) before focus moves to its nearest neighbour.
    @ObservationIgnored var recoveryDelay: Duration = .milliseconds(150)
    /// Screens that need a say in what B does (leave a detail pane, close a page). The most recent one is asked first; it returns true when it dealt with the press.
    @ObservationIgnored private var backChain: [(id: UUID, handler: () -> Bool)] = []
    /// The column (for up/down) or row (for left/right) focus has been travelling along, so it comes back to the same place after passing a wider or narrower item.
    @ObservationIgnored private var anchorX: CGFloat?
    @ObservationIgnored private var anchorY: CGFloat?
    /// The focused target disappeared; where it was, until it returns or the nearest neighbour takes over.
    @ObservationIgnored private var lost: (id: AnyHashable, frame: CGRect)?
    @ObservationIgnored private var recovery: Task<Void, Never>?

    /// The place a screen always starts: it is where the controller's first press lands, and with a controller connected the glow is put there at once (so it is
    /// always clear where you are when a section opens). `force` is for a screen opening; without it a later change of the list (reports arriving) only moves the glow
    /// while nobody has used the controller on the screen yet.
    func start(at id: AnyHashable, force: Bool = false) {
        defaultFocus = id
        if force { moved = false; engaged = nil }
        guard ControllerInput.shared.connected, force || !moved else { return }
        focused = id; scrollRequest = id; scrollTick += 1; resetAnchors()
    }

    func addBack(_ id: UUID, _ handler: @escaping () -> Bool) { backChain.removeAll { $0.id == id }; backChain.append((id, handler)) }
    func removeBack(_ id: UUID) { backChain.removeAll { $0.id == id } }

    func register(_ id: AnyHashable, frame: CGRect, action: (() -> Void)?, secondary: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil, label: String? = nil, secondaryLabel: String? = nil, engageToAdjust: Bool = false) {
        let changed = entries[id].map { $0.label != label || $0.secondaryLabel != secondaryLabel || ($0.secondary == nil) != (secondary == nil) || ($0.adjust == nil) != (adjust == nil) || $0.engageToAdjust != engageToAdjust } ?? true
        entries[id] = Entry(frame: frame, action: action, secondary: secondary, adjust: adjust, label: label, secondaryLabel: secondaryLabel, engageToAdjust: engageToAdjust)
        if changed, focused == id { hintsTick += 1 }
        if lost?.id == id { lost = nil; recovery?.cancel() }
    }

    /// A target went away. If it had focus, focus is not dropped on the spot (the view may be redrawn and come straight back); it moves to the nearest target if it does not.
    func unregister(_ id: AnyHashable) {
        let frame = entries[id]?.frame
        entries[id] = nil
        guard focused == id, let frame else { return }
        lost = (id, frame)
        recovery?.cancel()
        let delay = recoveryDelay
        recovery = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.recoverFocus()
        }
    }

    /// Moves focus off a vanished target to the nearest one (or clears it when the layer is empty).
    func recoverFocus() {
        guard let l = lost, focused == l.id, entries[l.id] == nil else { lost = nil; return }
        lost = nil
        // Scrolled by touch (nobody has used the D-pad lately): a tile that scrolled away just loses the glow; it must not jump to another tile under the finger.
        if NavHub.shared.pointerMayMoveFocus { focused = nil; resetAnchors(); return }
        let candidates = entries.map { (id: $0.key, frame: $0.value.frame) }
        focused = SpatialFocus.nearest(to: CGPoint(x: l.frame.midX, y: l.frame.midY), among: candidates)
        resetAnchors()
    }

    /// Focus put somewhere by a tap or the pointer rather than the D-pad: the remembered column no longer applies.
    func focus(_ id: AnyHashable) {
        guard focused != id else { return }
        focused = id
        engaged = nil
        resetAnchors()
    }
    private func resetAnchors() { anchorX = nil; anchorY = nil }

    func handle(_ command: NavCommand) {
        moved = true
        switch command {
        case .move(let direction): move(direction)
        case .select:
            if let id = focused, let entry = entries[id] {
                // A slider is gone into with A (Left / Right then change it) and left with A or B.
                if entry.engageToAdjust { engaged = engaged == id ? nil : id; hintsTick += 1 } else { entry.action?() }
            } else { ensureFocus() }
        case .secondary: if let s = focused.flatMap({ entries[$0]?.secondary }) { s() } else { onSecondary?() }
        case .back:
            if engaged != nil { engaged = nil; hintsTick += 1; return }
            for item in backChain.reversed() where item.handler() { return }
            onBack?()
        case .menu: onMenu?()
        case .tertiary: onTertiary?()
        case .previousSection: onSection?(-1)
        case .nextSection: onSection?(1)
        }
    }

    func ensureFocus() {
        if let id = focused, entries[id] != nil { return }
        let candidates = entries.map { (id: $0.key, frame: $0.value.frame) }
        if let d = defaultFocus, entries[d] != nil { focused = d } else { focused = SpatialFocus.first(among: candidates) }
        resetAnchors()
        scrollRequest = focused; scrollTick += 1
    }

    private func move(_ direction: NavDirection) {
        guard let current = focused, let from = entries[current]?.frame else { ensureFocus(); return }
        // Left / Right move the glow, never a setting, except on a slider that has been gone into (and the media viewer, which steps through its pictures).
        if let entry = entries[current], let adjust = entry.adjust, direction == .left || direction == .right, !entry.engageToAdjust || engaged == current { adjust(direction == .right ? 1 : -1); return }
        if engaged != nil { engaged = nil; hintsTick += 1 }
        let vertical = direction == .up || direction == .down
        // Moving up or down keeps the column it started in; moving left or right keeps the row.
        let anchor: CGFloat? = vertical ? (anchorX ?? from.midX) : (anchorY ?? from.midY)
        let candidates = entries.map { (id: $0.key, frame: $0.value.frame) }
        guard let next = SpatialFocus.next(from: from, among: candidates, direction: direction, excluding: current, anchor: anchor) else { return }
        if vertical { anchorX = anchor; anchorY = nil } else { anchorY = anchor; anchorX = nil }
        focused = next; scrollRequest = next; scrollTick += 1
    }
}
