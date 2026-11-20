// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import Observation
import UIKit

// Interactive tutorials ("coach marks"): a dimmed screen with a hole over the real button or row being explained, a card that says what it is and what it does, and a tutorial that moves
// on by itself when the person uses the highlighted thing (or presses Next). It follows the person from tab to tab and into sheets: each step can say how to get to its screen.
//
// Three parts: `CoachAnchors` (where things are on screen, by name), `Coach` (the tutorial that is running and its steps; this file), and the overlay window that draws it (CoachOverlay.swift).
// Nothing here knows the app: steps carry closures for "go there" and "has the app got there".

/// Where named things are on screen. A view names itself with `.coachTarget("id")`; every controller-focus target (`focusTarget`) does it too, with its own id, so most rows and buttons can
/// be pointed at without anything added. While a tutorial runs, each named view carries a tiny invisible UIKit view (`CoachProbe`); the tutorial reads where that view is drawn RIGHT NOW,
/// every display frame: the position on the screen including scrolling, a sheet sliding in, a page transition and the glow's zoom. (SwiftUI's own reported frames leave those out, and
/// the first version of the tutorials, built on them, pointed at the wrong place.) Nothing is measured while no tutorial runs.
@MainActor
final class CoachAnchors {
    static let shared = CoachAnchors()
    private struct Weak { weak var view: CoachProbeView? }
    private var probes: [String: [Weak]] = [:]

    func attach(_ id: String, _ view: CoachProbeView) {
        probes[id, default: []].removeAll { $0.view == nil || $0.view === view }
        probes[id]?.append(Weak(view: view))
    }

    func detach(_ id: String, _ view: CoachProbeView) {
        probes[id]?.removeAll { $0.view == nil || $0.view === view }
        if probes[id]?.isEmpty == true { probes[id] = nil }
    }

    /// Everything named `id` (an id ending in "*" stands for any name that starts the same) that is drawn on a screen that is up.
    private func live(_ id: String) -> [(name: String, view: CoachProbeView)] {
        if id.hasSuffix("*") {
            let prefix = String(id.dropLast())
            return probes.filter { $0.key.hasPrefix(prefix) }.flatMap { key, list in list.compactMap { w in w.view.flatMap { $0.isDrawn ? (key, $0) : nil } } }
        }
        return (probes[id] ?? []).compactMap { w in w.view.flatMap { $0.isDrawn ? (id, $0) : nil } }
    }

    /// The first of `ids` that is on screen, in `window`'s coordinates: the part of it that shows (not scrolled out, not clipped by a card or a sheet) is at least half of it.
    /// Of several matches (a wildcard, or the same name on two screens) the top-most, left-most is first.
    /// `topmost`: of everything the names match, across all of them, the one nearest the top (the first game in a list whose cards each have their own name). `group`: the box around everything
    /// the first matching name finds (a whole list of choices), not just one of them.
    func locate(_ ids: [String], in window: UIWindow?, group: Bool = false, topmost: Bool = false) -> (id: String, rect: CGRect)? {
        guard let window else { return nil }
        func shown(_ id: String) -> [(name: String, full: CGRect, visible: CGRect)] {
            live(id).compactMap { c -> (name: String, full: CGRect, visible: CGRect)? in
                guard let m = c.view.measure(in: window) else { return nil }
                return (c.name, m.full, m.visible)
            }
            .filter { $0.visible.width * $0.visible.height >= $0.full.width * $0.full.height * 0.5 && $0.visible.width > 1 && $0.visible.height > 1 }
            .sorted { ($0.visible.minY, $0.visible.minX) < ($1.visible.minY, $1.visible.minX) }
        }
        if topmost {
            let all = ids.flatMap(shown).sorted { ($0.visible.minY, $0.visible.minX) < ($1.visible.minY, $1.visible.minX) }
            return all.first.map { ($0.name, $0.visible) }
        }
        for id in ids {
            let found = shown(id)
            guard let best = found.first else { continue }
            if group, found.count > 1 { return (best.name, found.dropFirst().reduce(best.visible) { $0.union($1.visible) }) }
            return (best.name, best.visible)
        }
        return nil
    }

    /// Scrolls the screen that holds the first of `ids` so that it comes into view (centred when it can be). True when something was moved. A tutorial step whose target is on the screen but
    /// scrolled out of sight calls this, so the person is never told to go and look.
    @discardableResult
    func scrollIntoView(_ ids: [String]) -> Bool {
        for id in ids {
            guard let probe = live(id).map(\.view).min(by: { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }) else { continue }
            var up = probe.superview
            while let v = up {
                if let scroll = v as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 1 {
                    let r = probe.convert(probe.bounds, to: scroll)
                    let inset = scroll.adjustedContentInset
                    let low = -inset.top, high = max(low, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
                    // Centre the thing; a thing taller than the screen shows from its top.
                    let wanted = r.height >= scroll.bounds.height ? r.minY - inset.top - 12 : r.midY - scroll.bounds.height / 2
                    let y = min(max(wanted, low), high)
                    guard abs(y - scroll.contentOffset.y) > 2 else { return false }
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
                    return true
                }
                up = v.superview
            }
        }
        return false
    }

    /// Whether any of `ids` exists on a screen that is up, even if it is scrolled out of sight: the tutorial then says to scroll instead of saying it is lost.
    func exists(_ ids: [String]) -> Bool { ids.contains { !live($0).isEmpty } }
}

/// An invisible view that knows where it is drawn. It sits behind the thing it names, so it has that thing's size and moves with it.
final class CoachProbeView: UIView {
    var anchorID = ""

    /// On a screen that is up: in a window, not hidden (itself or any parent), and not under a sheet or cover that is presented over its screen.
    var isDrawn: Bool {
        guard let window else { return false }
        var v: UIView? = self
        while let x = v { if x.isHidden || x.alpha < 0.01 { return false }; v = x.superview }
        return !isCovered(in: window)
    }

    /// A sheet or cover presented over this view's screen hides it, though it stays in the window.
    private func isCovered(in window: UIWindow) -> Bool {
        guard let root = window.rootViewController, let owner = ownerController() else { return false }
        var top = root
        while let next = top.presentedViewController { top = next }
        if top === owner { return false }
        var c: UIViewController? = owner
        while let x = c { if x === top { return false }; c = x.parent }       // inside the top screen
        var below: UIViewController? = top.presentingViewController            // or is it one of the screens under it?
        while let x = below { var o: UIViewController? = owner; while let y = o { if y === x { return true }; o = y.parent }; below = x.presentingViewController }
        return false
    }

    private func ownerController() -> UIViewController? {
        var r: UIResponder? = self
        while let x = r { if let vc = x as? UIViewController { return vc }; r = x.next }
        return nil
    }

    /// Where it is drawn now, in `window`'s coordinates: the whole of it, and the part of it that shows after the scroll views and clipping parents around it. Uses the layers as they
    /// are drawn at this moment (an animation in flight included), not the positions the layout will end at.
    func measure(in target: UIWindow) -> (full: CGRect, visible: CGRect)? {
        guard let own = window else { return nil }
        // The rectangle is wanted in the coordinates the overlay draws in: those of the overlay's root view, which is not always the same as its window's (an iPad window can be inset or moved
        // inside its scene). UIKit's own view-to-view conversion goes through the screen, so it is right whatever the two windows' frames are.
        let space: UIView = target.rootViewController?.view ?? target
        func drawn(_ v: UIView) -> CALayer { v.layer.presentation() ?? v.layer }
        let l = drawn(self)
        var full = l.convert(l.bounds, to: own.layer)
        full = own.convert(full, to: space)
        var visible = full.intersection(space.bounds)
        var a = superview
        while let s = a, !visible.isNull {
            if s.clipsToBounds || s is UIScrollView {
                let sl = drawn(s)
                visible = visible.intersection(own.convert(sl.convert(sl.bounds, to: own.layer), to: space))
            }
            a = s.superview
        }
        guard full.width > 0, full.height > 0, !visible.isNull else { return nil }
        return (full, visible)
    }
}

/// Puts a probe behind a view while a tutorial runs.
struct CoachProbe: UIViewRepresentable {
    let id: String

    func makeUIView(context: Context) -> CoachProbeView {
        let v = CoachProbeView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        v.anchorID = id
        CoachAnchors.shared.attach(id, v)
        return v
    }

    func updateUIView(_ v: CoachProbeView, context: Context) {
        if v.anchorID != id { CoachAnchors.shared.detach(v.anchorID, v); v.anchorID = id; CoachAnchors.shared.attach(id, v) }
    }

    static func dismantleUIView(_ v: CoachProbeView, coordinator: ()) { CoachAnchors.shared.detach(v.anchorID, v) }
}

extension View {
    /// Lets a tutorial point at this view by `id`. Costs nothing until a tutorial runs.
    func coachTarget(_ id: String) -> some View { modifier(CoachTargetModifier(id: id)) }
}

struct CoachTargetModifier: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content.background { if Coach.shared.isActive { CoachProbe(id: id) } }
    }
}

/// A tap on the screen at a point, as the tutorial hears it.
enum CoachSide { case auto, above, below, leading, trailing }
enum CoachShape { case rounded, capsule, circle }

/// One step: what to point at, what to say, and how the person moves on.
struct CoachStep: Identifiable {
    enum Advance {
        /// The person presses Next. The highlighted thing is shown, not used.
        case next
        /// The person uses the highlighted thing (a tap on it), and the tutorial moves on.
        case tap
        /// Either: the highlighted thing can be used, and Next is there too (for a thing the person may have done already).
        case tapOrNext
        /// Moves on by itself as soon as this is true (the app has gone where the step wanted); the highlighted thing can be used. If it is already true when the step starts, the step is skipped.
        case until(() -> Bool)

        var usesTarget: Bool { if case .next = self { return false }; return true }
        var showsNext: Bool { switch self { case .next, .tapOrNext: true; default: false } }
    }

    let id: String
    /// Names tried in order; the first one on screen is highlighted. Empty: nothing is highlighted and the card sits in the middle (an introduction, an ending, a gesture).
    var anchors: [String] = []
    var title: String
    /// What it is and what it does, in a sentence or two.
    var text: String
    /// A few short lines under the text, one for each button or option in the highlighted group.
    var points: [CoachPoint] = []
    var advance: Advance = .next
    /// How to get to the screen this step is on: runs when the step starts and its target is not on screen (open a tab, a Settings page, a sheet).
    var ensure: (() -> Void)?
    /// The step does not apply (what it asks for is already done): it is skipped.
    var skipIf: (() -> Bool)?
    var shape: CoachShape = .rounded
    /// How far the hole reaches beyond the thing.
    var inset: CGFloat = 6
    var side: CoachSide = .auto
    /// Draws a swipe from this edge of the screen (the in-game menu opens that way).
    var swipeFrom: Edge?
    /// A line in the card's footer when the step is waiting for the person ("Tap Settings to continue").
    var prompt: String?
    /// Whether a touch on the highlighted thing reaches it. Nil: yes when the step is about using it (tap, until). Set it for a step that explains a text field the person types in.
    var interactive: Bool?
    /// False lets every touch through, not only the ones on the highlighted thing (a swipe from the screen's edge, a game's own screen).
    var blocks = true
    /// Shows Next on a step that otherwise moves on by itself, for a thing the person may not be able to do.
    var allowNext = false
    /// Highlights the box around everything the name matches (a list of choices), not only the first.
    var group = false
    /// Highlights the match nearest the top of the screen, whichever name it has (the first game in the list).
    var topmost = false

    var showsNext: Bool { advance.showsNext || allowNext }
    var usable: Bool { interactive ?? advance.usesTarget }
}

/// One line of "what each button does".
struct CoachPoint: Hashable {
    let symbol: String
    let text: String
}

struct CoachTutorial: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// One sentence for the list of tutorials.
    let summary: String
    /// Why this tutorial cannot start now (nil: it can).
    var unavailable: (() -> String?)?
    let steps: [CoachStep]
    /// About how long, for the list.
    var minutes: Int = 1
}

/// The tutorial that is running. One at a time; the overlay window and the screen's tap listener come and go with it.
@MainActor @Observable
final class Coach {
    static let shared = Coach()

    /// showing: the thing is on screen. waiting: looking for it (a screen is still opening). scrolling: it exists but is out of sight. missing: it is not there at all.
    enum Phase { case showing, waiting, scrolling, missing }

    private(set) var tutorial: CoachTutorial?
    private(set) var index = 0
    /// The thing being pointed at, in window coordinates and already grown by the step's inset; nil when the step points at nothing.
    private(set) var hole: CGRect?
    private(set) var phase: Phase = .showing
    private(set) var completed: Set<String>
    /// The measured rectangle itself, before it is grown. Drawn as a thin outline when `showRaw` is on (a developer switch for checking where a highlight lands).
    private(set) var rawRect: CGRect?
    var showRaw = false

    /// The card's frame, reported by the overlay so touches on it are not swallowed.
    @ObservationIgnored var cardFrame = CGRect.zero
    @ObservationIgnored var onEvent: ((String) -> Void)?
    /// Called when a tutorial starts or ends (the app pauses its own first-visit guides meanwhile).
    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?
    /// Called after a tutorial has ended, finished or closed by the person (the app takes them back to the list of tutorials).
    @ObservationIgnored var onFinish: ((CoachTutorial, Bool) -> Void)?

    private static let doneKey = "f4.coach.done"
    @ObservationIgnored private let overlay = CoachOverlayHost()
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var loggedStep: String?
    @ObservationIgnored private var stepStart = Date()
    @ObservationIgnored private var ensured = false
    @ObservationIgnored private var advancing = false
    @ObservationIgnored private var lastScroll = Date.distantPast
    @ObservationIgnored private var scrollTries = 0

    private init() { completed = Set(UserDefaults.standard.stringArray(forKey: Self.doneKey) ?? []) }

    var isActive: Bool { tutorial != nil }
    var step: CoachStep? { tutorial.flatMap { index < $0.steps.count ? $0.steps[index] : nil } }
    var count: Int { tutorial?.steps.count ?? 0 }
    var isLast: Bool { index >= count - 1 }

    /// Whether the thing being pointed at can be used (a tap goes through to it) at this moment.
    var holeIsUsable: Bool { phase == .showing && hole != nil && (step?.usable ?? false) }
    /// Whether the dimmed screen takes touches (everything but the hole and the card). Off while the tutorial cannot find what it points at, or the person has to scroll to it,
    /// so the person is never stuck.
    var blocksScreen: Bool { (phase == .showing || phase == .waiting) && (step?.blocks ?? true) }

    func isDone(_ id: String) -> Bool { completed.contains(id) }

    // MARK: Running

    @discardableResult
    func start(_ t: CoachTutorial) -> Bool {
        if let why = t.unavailable?() { onEvent?("[coach] \(t.id) not started: \(why)"); return false }
        stop(completedIt: false)
        guard !t.steps.isEmpty, overlay.show() else { return false }
        tutorial = t; index = 0; hole = nil
        onActiveChange?(true)
        onEvent?("[coach] started \(t.id)")
        beginStep()
        // Every display frame: the thing pointed at moves with a scroll, a sheet or a page change, and the hole has to stay on it.
        let proxy = CoachLinkProxy(self)
        let l = CADisplayLink(target: proxy, selector: #selector(CoachLinkProxy.fire))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
        return true
    }

    /// Ends the tutorial. `completedIt` marks it as finished (the person got to the last step).
    func stop(completedIt: Bool) {
        guard let t = tutorial else { return }
        link?.invalidate(); link = nil
        if completedIt { completed.insert(t.id); UserDefaults.standard.set(Array(completed), forKey: Self.doneKey) }
        onEvent?("[coach] \(completedIt ? "finished" : "stopped") \(t.id) at step \(index + 1) of \(t.steps.count)")
        overlay.hide()
        tutorial = nil; hole = nil; index = 0; phase = .showing
        onActiveChange?(false)
        onFinish?(t, completedIt)
    }

    func next() {
        guard tutorial != nil, !advancing else { return }
        if isLast { stop(completedIt: true) } else { index += 1; beginStep() }
    }

    func back() {
        guard tutorial != nil, index > 0 else { return }
        index -= 1; beginStep(skipping: false)
    }

    func resetProgress() { completed = []; UserDefaults.standard.set([String](), forKey: Self.doneKey) }

    /// The overlay's tap listener: a tap inside the hole is the person using the thing, and the tutorial moves on once the app has answered.
    /// `point` is in the overlay's root view coordinates.
    func screenTapped(at point: CGPoint) {
        guard holeIsUsable, step?.advance.usesTarget == true, let hole, hole.insetBy(dx: -4, dy: -4).contains(point), !advancing else { return }
        advanceSoon(after: 0.5)
    }

    // MARK: Steps

    private func beginStep(skipping: Bool = true) {
        guard let step else { return }
        stepStart = Date(); ensured = false; advancing = false; phase = .showing; scrollTries = 0; lastScroll = Date.distantPast
        if skipping {
            if let skip = step.skipIf, skip() { onEvent?("[coach] \(step.id) skipped: already done"); next(); return }
            if case .until(let done) = step.advance, done() { onEvent?("[coach] \(step.id) skipped: already true"); next(); return }
        }
        locate()
        if hole == nil, !step.anchors.isEmpty, let ensure = step.ensure { ensured = true; ensure() }
    }

    private func advanceSoon(after delay: TimeInterval) {
        advancing = true
        let at = index
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard let self, self.index == at, self.tutorial != nil else { return }
            self.advancing = false
            self.next()
        }
    }

    fileprivate func tick() {
        guard let step, !advancing else { return }
        if case .until(let done) = step.advance, done() { advanceSoon(after: 0.35); return }
        locate()
        if hole == nil, !step.anchors.isEmpty {
            let waited = Date().timeIntervalSince(stepStart)
            if !ensured, waited > 1.5, let ensure = step.ensure { ensured = true; ensure() }
            if CoachAnchors.shared.exists(step.anchors) {                           // it is on this screen, just not in view: the screen scrolls to it
                phase = .scrolling
                if scrollTries < 8, Date().timeIntervalSince(lastScroll) > 0.7 {
                    lastScroll = Date(); scrollTries += 1
                    if CoachAnchors.shared.scrollIntoView(step.anchors) { onEvent?("[coach] \(step.id): scrolled to \(step.anchors.first ?? "?")") }
                }
            }
            else { phase = waited > 6 ? .missing : (waited > 0.5 ? .waiting : .showing) }
        } else { phase = .showing }
    }

    private func locate() {
        guard let step else { return }
        if step.anchors.isEmpty { if hole != nil { hole = nil }; return }
        guard let found = CoachAnchors.shared.locate(step.anchors, in: overlay.overlayWindow, group: step.group, topmost: step.topmost) else { if hole != nil { hole = nil }; return }
        let grown = found.rect.insetBy(dx: -step.inset, dy: -step.inset)
        rawRect = found.rect
        if loggedStep != step.id {
            // What a report of a wrong highlight needs: which name was found, where, and how big the screen is.
            loggedStep = step.id
            onEvent?("[coach] \(tutorial?.id ?? "?") step \(step.id): \(found.id) at x \(Int(found.rect.minX)) y \(Int(found.rect.minY)) w \(Int(found.rect.width)) h \(Int(found.rect.height)), screen \(Int(overlay.bounds.width))x\(Int(overlay.bounds.height))")
        }
        if hole != grown {
            // A jump to somewhere else glides; a thing that scrolls under the person's finger is followed without lag.
            let far = hole.map { abs($0.midX - grown.midX) + abs($0.midY - grown.midY) > 60 } ?? true
            if far { withAnimation(.easeInOut(duration: 0.3)) { hole = grown } } else { hole = grown }
        }
    }
}

/// CADisplayLink keeps its target alive; this holds the tutorial weakly.
private final class CoachLinkProxy: NSObject {
    weak var coach: Coach?
    init(_ coach: Coach) { self.coach = coach }
    @objc func fire() { MainActor.assumeIsolated { coach?.tick() } }
}

/// Where the card goes: beside the highlighted thing, on the side with the most room, with its arrow on the edge that faces it. Pure geometry, so it is tested without a screen.
enum CoachLayout {
    enum Arrow { case top, bottom, leading, trailing }
    struct Placement: Equatable {
        var frame: CGRect
        /// The card's edge that carries the arrow (nil when the card does not touch the highlight), and where along that edge it points, in the card's own coordinates.
        var arrow: Arrow?
        var arrowAt: CGFloat
    }

    static func place(card: CGSize, hole: CGRect?, in area: CGRect, side: CoachSide = .auto, gap: CGFloat = 16) -> Placement {
        let w = min(card.width, area.width), h = min(card.height, area.height)
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, area.minX), area.maxX - w) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, area.minY), area.maxY - h) }
        guard let hole else { return Placement(frame: CGRect(x: clampX(area.midX - w / 2), y: clampY(area.midY - h / 2), width: w, height: h), arrow: nil, arrowAt: 0) }

        let room: [(CoachSide, CGFloat)] = [(.below, area.maxY - hole.maxY - gap), (.above, hole.minY - area.minY - gap),
                                           (.trailing, area.maxX - hole.maxX - gap), (.leading, hole.minX - area.minX - gap)]
        func fits(_ s: CoachSide) -> Bool {
            switch s {
            case .below, .above: return (room.first { $0.0 == s }?.1 ?? 0) >= h
            case .trailing, .leading: return (room.first { $0.0 == s }?.1 ?? 0) >= w
            case .auto: return false
            }
        }
        // The side asked for, then the vertical sides (a card reads better above or below), by room; then the horizontal ones.
        var order: [CoachSide] = []
        if side != .auto { order.append(side) }
        order += room.filter { $0.0 == .below || $0.0 == .above }.sorted { $0.1 > $1.1 }.map(\.0)
        order += room.filter { $0.0 == .trailing || $0.0 == .leading }.sorted { $0.1 > $1.1 }.map(\.0)
        guard let chosen = order.first(where: fits) else {
            // The highlight is too big to put the card beside it: the card sits over the larger of the top and the bottom, with no arrow.
            let top = hole.midY > area.midY
            return Placement(frame: CGRect(x: clampX(hole.midX - w / 2), y: top ? area.minY : area.maxY - h, width: w, height: h), arrow: nil, arrowAt: 0)
        }
        switch chosen {
        case .below, .above:
            let x = clampX(hole.midX - w / 2)
            let y = chosen == .below ? hole.maxY + gap : hole.minY - gap - h
            return Placement(frame: CGRect(x: x, y: y, width: w, height: h), arrow: chosen == .below ? .top : .bottom, arrowAt: min(max(hole.midX - x, 22), w - 22))
        default:
            let y = clampY(hole.midY - h / 2)
            let x = chosen == .trailing ? hole.maxX + gap : hole.minX - gap - w
            return Placement(frame: CGRect(x: x, y: y, width: w, height: h), arrow: chosen == .trailing ? .leading : .trailing, arrowAt: min(max(hole.midY - y, 22), h - 22))
        }
    }
}
