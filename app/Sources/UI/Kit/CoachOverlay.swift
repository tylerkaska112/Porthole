// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import UIKit

// What a running tutorial looks like: a window of its own above everything (sheets, the setup guide, a running game's menu), so it can point at anything. The window takes the touches the
// tutorial wants (outside the hole, so the person stays on the path), lets the ones on the highlighted thing through to the real button, and never becomes the key window (a key window takes
// the game's picture into itself; see PassthroughWindow in LaunchOverlay.swift).

/// A window that asks the tutorial what to do with each touch.
final class CoachWindow: UIWindow {
    enum Hit { case swallow, passThrough, card }
    var decide: ((CGPoint) -> Hit)?
    override var canBecomeKey: Bool { false }

    /// A point of this window in the coordinates the overlay is drawn in (its root view's).
    func hostPoint(_ p: CGPoint) -> CGPoint { rootViewController?.view.convert(p, from: self) ?? p }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        switch decide?(hostPoint(point)) ?? .passThrough {
        case .passThrough: return nil
        case .card: return super.hitTest(point, with: event) ?? rootViewController?.view
        case .swallow: return rootViewController?.view
        }
    }
}

/// Listens for taps in the app's own windows without taking them: a tap on the highlighted thing is how a tutorial hears that it was used.
private final class CoachTapListener: NSObject, UIGestureRecognizerDelegate {
    var onTap: ((CGPoint, UIWindow) -> Void)?
    private(set) var attached: [(window: UIWindow, recognizer: UITapGestureRecognizer)] = []

    func attach(to window: UIWindow) {
        guard !attached.contains(where: { $0.window === window }) else { return }
        let r = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        r.cancelsTouchesInView = false
        r.delaysTouchesBegan = false
        r.delaysTouchesEnded = false
        r.delegate = self
        window.addGestureRecognizer(r)
        attached.append((window, r))
    }

    func detachAll() {
        for a in attached { a.window.removeGestureRecognizer(a.recognizer) }
        attached = []
    }

    @objc private func tapped(_ r: UITapGestureRecognizer) {
        guard r.state == .ended, let window = r.view as? UIWindow else { return }
        onTap?(r.location(in: window), window)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

@MainActor
final class CoachOverlayHost {
    private var window: CoachWindow?
    private let listener = CoachTapListener()
    private var attachTimer: Timer?

    var bounds: CGRect { window?.bounds ?? UIScreen.main.bounds }
    /// The tutorial's own window: positions are measured into its coordinates, the ones the ring and the hole are drawn in.
    var overlayWindow: UIWindow? { window }

    /// Puts the overlay on screen. False when the app has no scene to put it in.
    func show() -> Bool {
        guard window == nil else { return true }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first(where: { $0.activationState != .unattached }) else { return false }
        let w = CoachWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level.alert + 30        // above the launch screen's window and the game
        let host = UIHostingController(rootView: CoachOverlayView())
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.backgroundColor = .clear
        w.decide = { point in
            let coach = Coach.shared
            if coach.cardFrame.insetBy(dx: -4, dy: -4).contains(point) { return .card }
            if coach.holeIsUsable, let hole = coach.hole, hole.contains(point) { return .passThrough }
            return coach.blocksScreen ? .swallow : .passThrough
        }
        w.alpha = 0
        w.isHidden = false
        window = w
        UIView.animate(withDuration: 0.2) { w.alpha = 1 }
        listener.onTap = { [weak w] point, from in
            guard let w, let host = w.rootViewController?.view else { return }
            Coach.shared.screenTapped(at: host.convert(point, from: from))
        }
        Coach.shared.onEvent?(geometryReport(w))
        attachListener()
        // A window that opens later (a game starts) gets the listener too.
        attachTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.attachListener() } }
        RunLoop.main.add(attachTimer!, forMode: .common)
        return true
    }

    /// Every window's frame and the overlay's root view, for a report of a highlight in the wrong place.
    private func geometryReport(_ own: CoachWindow) -> String {
        let scene = own.windowScene
        var parts = ["[coach] geometry: scene \(rect(scene?.coordinateSpace.bounds ?? .zero)), screen \(rect(own.screen.bounds)) @\(own.screen.scale)x, overlay window \(rect(own.frame)), overlay root \(rect(own.rootViewController?.view.frame ?? .zero)) safe \(inset(own.safeAreaInsets))"]
        for w in scene?.windows ?? [] where w !== own { parts.append("app window \(rect(w.frame)) level \(Int(w.windowLevel.rawValue)) safe \(inset(w.safeAreaInsets))") }
        return parts.joined(separator: "; ")
    }
    private func rect(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))" }
    private func inset(_ i: UIEdgeInsets) -> String { "\(Int(i.top))/\(Int(i.left))/\(Int(i.bottom))/\(Int(i.right))" }

    func hide() {
        attachTimer?.invalidate(); attachTimer = nil
        listener.detachAll()
        guard let w = window else { return }
        window = nil
        UIView.animate(withDuration: 0.2, animations: { w.alpha = 0 }, completion: { _ in w.isHidden = true })
    }

    private func attachListener() {
        guard let own = window, let scene = own.windowScene else { return }
        for w in scene.windows where w !== own { listener.attach(to: w) }
    }
}

// MARK: - Drawing

/// The dimmed screen with a rounded hole in it. The hole's rectangle is animatable, so it glides from one thing to the next.
private struct CoachDim: Shape {
    var hole: CGRect
    var shape: CoachShape
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(hole.origin.x, hole.origin.y), .init(hole.size.width, hole.size.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if hole.width > 0, hole.height > 0 { p.addPath(CoachDim.cutout(hole, shape)) }
        return p
    }

    static func cutout(_ r: CGRect, _ shape: CoachShape) -> Path {
        switch shape {
        case .circle: return Path(ellipseIn: CGRect(x: r.midX - max(r.width, r.height) / 2, y: r.midY - max(r.width, r.height) / 2, width: max(r.width, r.height), height: max(r.width, r.height)))
        case .capsule: return Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2)
        case .rounded: return Path(roundedRect: r, cornerRadius: min(16, min(r.width, r.height) / 2))
        }
    }
}

private struct CoachTriangle: Shape {
    var arrow: CoachLayout.Arrow
    func path(in r: CGRect) -> Path {
        var p = Path()
        switch arrow {
        case .top: p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        case .bottom: p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        case .leading: p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        case .trailing: p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}

struct CoachOverlayView: View {
    private var coach: Coach { Coach.shared }
    @State private var pulse = false
    @State private var cardSize = CGSize(width: 340, height: 180)
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        GeometryReader { geo in
            let screen = CGRect(origin: .zero, size: geo.size)
            let area = screen.inset(by: UIEdgeInsets(top: max(geo.safeAreaInsets.top, 12), left: max(geo.safeAreaInsets.leading, 12), bottom: max(geo.safeAreaInsets.bottom, 12), right: max(geo.safeAreaInsets.trailing, 12)))
            let hole = coach.hole
            let placement = CoachLayout.place(card: cardSize, hole: coach.phase == .showing ? hole : nil, in: area, side: coach.step?.side ?? .auto)
            ZStack(alignment: .topLeading) {
                dim(screen: screen, hole: hole)
                if let hole, coach.phase == .showing, let step = coach.step { ring(hole, step) }
                if coach.showRaw, let raw = coach.rawRect {
                    Rectangle().strokeBorder(Color.red, lineWidth: 1).frame(width: raw.width, height: raw.height).position(x: raw.midX, y: raw.midY).allowsHitTesting(false)
                }
                if let edge = coach.step?.swipeFrom { SwipeHint(edge: edge, size: geo.size) }
                if coach.step != nil { card(width: min(380, area.width), placement: placement) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }

    // The screen, dimmed, with the highlighted thing left bright. While the tutorial is looking for its target the dim is lighter, so a sheet sliding in is not hidden.
    private func dim(screen: CGRect, hole: CGRect?) -> some View {
        let shown = coach.phase == .showing || hole != nil
        let target = hole ?? CGRect(x: screen.midX, y: screen.midY, width: 0, height: 0)
        return CoachDim(hole: target, shape: coach.step?.shape ?? .rounded)
            .fill(Color.black.opacity(level(shown: shown)), style: FillStyle(eoFill: true))
            .animation(.easeInOut(duration: 0.25), value: level(shown: shown))
            .allowsHitTesting(false)
    }

    /// How dark the screen is: fully while the thing is shown, lightly while looking for it, not at all when it cannot be found. A step that lets touches through to a game is lighter.
    private func level(shown: Bool) -> Double {
        switch coach.phase {
        case .missing: 0
        case .scrolling: 0.3
        default: (coach.step?.blocks ?? true) ? (shown ? 0.68 : 0.35) : 0.3
        }
    }

    private func ring(_ hole: CGRect, _ step: CoachStep) -> some View {
        let usable = step.advance.usesTarget
        // The pulse scales the ring about ITS OWN centre, before it is placed. (Scaling the placed layer scaled the whole screen about the screen's centre, so a ring near a corner
        // drifted by 2.5 percent of its distance from the middle: about 9 points on an iPad.)
        let outline = Group {
            switch step.shape {
            case .circle:
                let d = max(hole.width, hole.height)
                Circle().strokeBorder(Theme.accentGradient, lineWidth: 3).frame(width: d, height: d)
            case .capsule: Capsule().strokeBorder(Theme.accentGradient, lineWidth: 3).frame(width: hole.width, height: hole.height)
            case .rounded: RoundedRectangle(cornerRadius: min(16, min(hole.width, hole.height) / 2), style: .continuous).strokeBorder(Theme.accentGradient, lineWidth: 3)
                    .frame(width: hole.width, height: hole.height)
            }
        }
        .shadow(color: Theme.accent.opacity(pulse ? 0.9 : 0.35), radius: pulse ? 14 : 5)
        .scaleEffect(pulse ? 1.025 : 1)
        return ZStack {
            outline.position(x: hole.midX, y: hole.midY)
            if usable {
                // A finger that taps: the thing is meant to be pressed.
                Image(systemName: "hand.tap.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 4)
                    .position(x: min(hole.maxX, hole.midX + 24), y: hole.maxY + 6 + (pulse ? 6 : 0))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func card(width: CGFloat, placement: CoachLayout.Placement) -> some View {
        if let step = coach.step { cardBody(step, width: width, placement: placement) }
    }

    private func cardBody(_ step: CoachStep, width: CGFloat, placement: CoachLayout.Placement) -> some View {
        let missing = coach.phase == .missing
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(coach.tutorial?.title ?? "").font(.system(size: 11, weight: .bold, design: .rounded)).textCase(.uppercase).tracking(0.5).foregroundStyle(Theme.textDim).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(coach.index + 1) of \(coach.count)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textDim)
                Button { coach.stop(completedIt: false) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.textDim).frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("End the tutorial")
            }
            Text(step.title).font(.system(size: 19, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Text(missing ? "I can't find this on the screen. Go to the right screen yourself, or skip this step." : (coach.phase == .scrolling ? "\(step.title) is further along this screen. Scroll to bring it into view; I will point at it." : step.text))
                .font(.system(size: 14.5)).foregroundStyle(Theme.text.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            if !step.points.isEmpty && !missing {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(step.points, id: \.self) { p in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: p.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent).frame(width: 20)
                            Text(p.text).font(.system(size: 13.5)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            footer(step: step, missing: missing)
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background {
            // Solid: the panel colour alone lets the screen show through, and the words would sit on a busy picture.
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.background)
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.panelHigh)
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.2))
        .overlay { arrow(placement, width: width) }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { measured(g.size) }
                .onChange(of: g.size) { _, s in measured(s) }
        })
        .offset(x: placement.frame.minX, y: placement.frame.minY)
        .animation(.easeInOut(duration: 0.28), value: placement.frame)
        .onChange(of: placement.frame) { _, f in coach.cardFrame = f }
        .onAppear { coach.cardFrame = placement.frame }
        .id(coach.index)
        .transition(.opacity)
    }

    private func measured(_ s: CGSize) { if abs(s.height - cardSize.height) > 0.5 || abs(s.width - cardSize.width) > 0.5 { cardSize = s } }

    @ViewBuilder private func footer(step: CoachStep, missing: Bool) -> some View {
        HStack(spacing: 10) {
            if coach.index > 0 {
                Button { coach.back() } label: {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).frame(minHeight: 38).background(Theme.panel, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if coach.phase == .waiting && !missing {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("One moment\u{2026}").font(.system(size: 13)).foregroundStyle(Theme.textDim) }
            } else if !missing, coach.phase == .showing, step.advance.usesTarget, !step.showsNext {
                Label(step.prompt ?? "Tap the highlighted button", systemImage: "hand.tap.fill").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 4)
            if missing {
                Button { coach.next() } label: { primary("Skip this step", "forward.fill") }.buttonStyle(.plain)
            } else if step.showsNext || coach.isLast || coach.phase == .scrolling {
                Button { coach.next() } label: { primary(coach.isLast ? "Done" : "Next", coach.isLast ? "checkmark" : "chevron.right") }.buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    private func primary(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).labelStyle(TrailingIcon()).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16).frame(minHeight: 38).background(Theme.accentGradient, in: Capsule())
    }

    @ViewBuilder private func arrow(_ p: CoachLayout.Placement, width: CGFloat) -> some View {
        if let a = p.arrow, coach.phase == .showing {
            let size = CGSize(width: 22, height: 11)
            CoachTriangle(arrow: a).fill(Theme.background)
                .overlay(CoachTriangle(arrow: a).fill(Theme.panelHigh))
                .frame(width: (a == .top || a == .bottom) ? size.width : size.height, height: (a == .top || a == .bottom) ? size.height : size.width)
                .overlay(CoachTriangle(arrow: a).stroke(Theme.accent.opacity(0.55), lineWidth: 1.2))
                .position(arrowPoint(a, at: p.arrowAt, card: p.frame.size))
        }
    }

    private func arrowPoint(_ a: CoachLayout.Arrow, at: CGFloat, card: CGSize) -> CGPoint {
        switch a {
        case .top: CGPoint(x: at, y: -5)
        case .bottom: CGPoint(x: at, y: card.height + 5)
        case .leading: CGPoint(x: -5, y: at)
        case .trailing: CGPoint(x: card.width + 5, y: at)
        }
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon.font(.system(size: 12, weight: .heavy)) }
    }
}

/// Chevrons sliding in from a screen edge: the way a swipe goes.
private struct SwipeHint: View {
    let edge: Edge
    let size: CGSize
    @State private var go = false

    var body: some View {
        let right = edge == .trailing
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: right ? "chevron.left" : "chevron.right").font(.system(size: 34, weight: .heavy)).opacity(1 - Double(i) * 0.3)
            }
        }
        .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 5)
        .position(x: right ? size.width - 50 - (go ? 70 : 0) : 50 + (go ? 70 : 0), y: size.height * 0.5)
        .opacity(go ? 0.2 : 1)
        .overlay(alignment: right ? .trailing : .leading) { Capsule().fill(Theme.accent).frame(width: 6, height: 70).position(x: right ? size.width - 3 : 3, y: size.height * 0.5) }
        .onAppear { withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) { go = true } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
