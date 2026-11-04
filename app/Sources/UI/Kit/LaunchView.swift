// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

struct LaunchStepData: Identifiable, Equatable {
    enum State { case pending, active, done }
    let id: String
    var title: String
    var state: State
}

struct LaunchSettingChip: Identifiable, Equatable {
    var id: String { text }
    var symbol: String
    var text: String
}

struct LaunchData: Equatable {
    var gameID: UUID
    var name: String
    var steps: [LaunchStepData]
    /// What is happening right now, in a few words ("Signing in to Steam").
    var headline: String
    /// Longer detail, shown behind the (i).
    var detail: String?
    var chips: [LaunchSettingChip]
    var failure: String?
    /// False once the game's program is running: it cannot be taken back, so the button becomes "Stop game".
    var cleanCancel = true
    /// When Play was pressed, for the running time on the screen.
    var began: Date?

    var progress: Double {
        guard !steps.isEmpty else { return 0 }
        let done = Double(steps.filter { $0.state == .done }.count)
        return min(1, (done + (steps.contains { $0.state == .active } ? 0.5 : 0)) / Double(steps.count))
    }
}

/// What the person sees from pressing Play until the game's own window appears: the game in a porthole with a glowing progress ring, what is happening right now in large type with what
/// it means underneath, a segmented bar that counts the steps, and the way out. The full list of steps is one tap away. When the launch fails the same screen turns into a card that says
/// why, which can be read for as long as it takes and copied.
struct LaunchView: View {
    let data: LaunchData
    /// Owned by whoever shows the screen, so it can take the layer away from the controller when the screen goes.
    let scope: FocusScope
    let cancel: () -> Void
    var showSteam: (() -> Void)?
    @Environment(\.verticalSizeClass) private var vSize
    @State private var copied = false
    @State private var showSteps = false

    private var failed: Bool { data.failure != nil }

    var body: some View {
        ZStack {
            background
            GeometryReader { geo in
                let wide = geo.size.width > geo.size.height * 1.05
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        if wide {
                            HStack(alignment: .center, spacing: 48) {
                                column(centered: false).frame(maxWidth: 520, alignment: .leading)
                                Porthole(data: data, size: min(geo.size.height * (vSize == .compact ? 0.66 : 0.6), 330))
                            }
                        } else {
                            VStack(spacing: 24) {
                                Porthole(data: data, size: min(geo.size.width * 0.58, 250))
                                column(centered: true).frame(maxWidth: 520)
                            }
                        }
                    }
                    .padding(.horizontal, wide ? 56 : 24).padding(.vertical, vSize == .compact ? 14 : 30)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .navScope(scope)
        .onAppear { scope.onBack = cancel; scope.defaultFocus = "launch-cancel"; scope.focused = "launch-cancel" }
        .preferredColorScheme(.dark)
    }

    // MARK: Pieces

    private var background: some View {
        ZStack {
            Color.black
            Color.clear.overlay { GameArtView(id: data.gameID, name: data.name, kind: .hero).blur(radius: 22).scaleEffect(1.12).opacity(failed ? 0.45 : 0.8) }.clipped()
            LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.45), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [(failed ? Theme.bad : Theme.accent).opacity(0.26 * max(Theme.glowStrength, 0.4)), .clear], center: .init(x: 0.5, y: 0.22), startRadius: 0, endRadius: 560)
        }
        .animation(.easeInOut(duration: 0.4), value: failed)
        .overlay(alignment: .topLeading) { if halloweenOn { HalloweenWeb(corner: .topLeading, size: 120, spider: true) } }
        .ignoresSafeArea()
    }

    /// Everything but the porthole.
    private func column(centered: Bool) -> some View {
        let tight = vSize == .compact
        let alignment: HorizontalAlignment = centered ? .center : .leading
        let textAlign: TextAlignment = centered ? .center : .leading
        return VStack(alignment: alignment, spacing: tight ? 10 : 14) {
            Text(data.name).font(.system(size: tight ? 14 : 15, weight: .heavy, design: .rounded)).tracking(1.2).textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.62)).lineLimit(2).multilineTextAlignment(textAlign)
            if let failure = data.failure {
                failureCard(failure)
            } else {
                VStack(alignment: alignment, spacing: 6) {
                    Text(data.headline).font(.system(size: tight ? 24 : 30, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        .multilineTextAlignment(textAlign).fixedSize(horizontal: false, vertical: true).contentTransition(.opacity)
                    if let detail = data.detail {
                        Text(detail).font(.system(size: 14, design: .rounded)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(textAlign)
                            .fixedSize(horizontal: false, vertical: true).lineLimit(tight ? 2 : 4)
                    }
                    patience(textAlign: textAlign)
                }
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                .animation(.easeInOut(duration: 0.25), value: data.headline)
                progress(centered: centered)
                if !data.chips.isEmpty { chips(centered: centered) }
            }
            buttons.padding(.top, tight ? 0 : 4)
        }
    }

    /// After a while: it is still working, and a first start really can take minutes.
    private func patience(textAlign: TextAlignment) -> some View {
        Group {
            if let began = data.began {
                TimelineView(.periodic(from: began, by: 1)) { context in
                    if context.date.timeIntervalSince(began) > 45 {
                        Label("Still working. The first start of a game can take a few minutes while it builds its caches.", systemImage: "hourglass")
                            .font(.footnote.weight(.medium)).foregroundStyle(Theme.accent.opacity(0.9)).multilineTextAlignment(textAlign).fixedSize(horizontal: false, vertical: true).transition(.opacity)
                    }
                }
            }
        }
    }

    /// The segmented bar, "Step 3 of 5" with the running time, and the list of all the steps behind a tap.
    private func progress(centered: Bool) -> some View {
        let done = data.steps.filter { $0.state == .done }.count
        let current = min(data.steps.count, done + (data.steps.contains { $0.state == .active } ? 1 : 0))
        return VStack(spacing: 10) {
            SegmentBar(steps: data.steps)
            HStack {
                Text("Step \(max(1, current)) of \(data.steps.count)").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7)).contentTransition(.numericText())
                Spacer()
                if let began = data.began { ElapsedLabel(since: began) }
            }
            .animation(.easeInOut(duration: 0.25), value: current)
            Button { withAnimation(.easeInOut(duration: 0.25)) { showSteps.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(showSteps ? "Hide the steps" : "Show all steps").font(.system(size: 13, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(showSteps ? 180 : 0))
                }
                .foregroundStyle(.white.opacity(0.6)).padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .focusTarget("launch-steps", radius: 12, scale: 1.04) { withAnimation(.easeInOut(duration: 0.25)) { showSteps.toggle() } }
            if showSteps {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(data.steps.enumerated()), id: \.element.id) { index, step in
                        StepRow(step: step, isLast: index == data.steps.count - 1, compact: vSize == .compact)
                    }
                }
                .padding(vSize == .compact ? 12 : 16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }

    /// How the game is being started, as one quiet line: Through Steam \u{00B7} 1280 \u{00D7} 720 \u{00B7} Balanced.
    private func chips(centered: Bool) -> some View {
        Text(data.chips.map { $0.text.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: "  \u{00B7}  ")).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(centered ? .center : .leading).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    /// Why the launch failed, in a card of its own: selectable, and it stays until it is closed.
    private func failureCard(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Couldn't start", systemImage: "exclamationmark.triangle.fill").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(Theme.bad)
            Text(failure).font(.system(size: 17, design: .rounded)).foregroundStyle(.white).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bad.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.bad.opacity(0.45), lineWidth: 1))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            PillButton(id: "launch-cancel", title: failed ? "Close" : (data.cleanCancel ? "Cancel" : "Stop game"), symbol: failed ? "xmark" : "stop.fill",
                       style: failed ? .glass : .danger, action: cancel)
            if let failure = data.failure {
                PillButton(id: "launch-copy", title: copied ? "Copied" : "Copy the message", symbol: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = "\(data.name): \(failure)"
                    copied = true
                }
            } else if let showSteam {
                PillButton(id: "launch-steam", title: "Show Steam window", symbol: "rectangle.on.rectangle", action: showSteam)
            }
        }
    }

    // MARK: Small parts

    /// One capsule per step: lit for the ones done, pulsing for the one running, dim for the rest.
    private struct SegmentBar: View {
        let steps: [LaunchStepData]
        var body: some View {
            HStack(spacing: 6) {
                ForEach(steps) { step in
                    ZStack {
                        Capsule().fill(.white.opacity(0.14))
                        switch step.state {
                        case .done: Capsule().fill(Theme.accentGradient).transition(.opacity)
                        case .active: PulsingCapsule()
                        case .pending: EmptyView()
                        }
                    }
                    .frame(height: 6)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: steps)
        }
    }

    private struct PulsingCapsule: View {
        @State private var lit = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            Capsule().fill(Theme.accent).opacity(lit ? 0.95 : 0.4)
                .shadow(color: Theme.accent.opacity(0.7 * Theme.glowStrength), radius: 5)
                .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true } } else { lit = true } }
        }
    }

    /// How long the launch has taken, as 0:47.
    private struct ElapsedLabel: View {
        let since: Date
        var body: some View {
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                Label(String(format: "%d:%02d", seconds / 60, seconds % 60), systemImage: "clock").labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    /// One step of the list, with the line that joins it to the next.
    private struct StepRow: View {
        let step: LaunchStepData
        let isLast: Bool
        var compact = false

        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                indicator.frame(width: 24, height: 24)
                Text(step.title).font(.system(size: compact ? 14 : 16, weight: step.state == .active ? .bold : .medium, design: .rounded))
                    .foregroundStyle(step.state == .pending ? .white.opacity(0.4) : .white)
                Spacer(minLength: 0)
            }
            .padding(.bottom, isLast ? 0 : (compact ? 6 : 14))
            .background(alignment: .topLeading) {
                if !isLast {
                    Rectangle().fill(step.state == .done ? Theme.good.opacity(0.55) : .white.opacity(0.14)).frame(width: 2).padding(.top, 25).padding(.leading, 11)
                }
            }
        }

        @ViewBuilder private var indicator: some View {
            switch step.state {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
                    .frame(width: 22, height: 22).background(Theme.good, in: Circle()).transition(.scale.combined(with: .opacity))
            case .active:
                ZStack {
                    Circle().strokeBorder(Theme.accent.opacity(0.9), lineWidth: 2).shadow(color: Theme.accent.opacity(0.9 * Theme.glowStrength), radius: 6)
                    ProgressView().controlSize(.mini).tint(.white)
                }
                .frame(width: 22, height: 22)
            case .pending:
                Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1.5).frame(width: 20, height: 20)
            }
        }
    }
}

// MARK: - The porthole

/// The game in a ship's porthole: a brushed-metal rim with bolts, the picture behind the glass, and a glowing ring inside it that fills as the launch moves on. When the launch fails
/// the ring turns red, the picture dims and a badge says so.
private struct Porthole: View {
    let data: LaunchData
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var failed: Bool { data.failure != nil }
    private var tint: Color { failed ? Theme.bad : Theme.accent }
    private var rim: CGFloat { size * 0.085 }

    var body: some View {
        ZStack {
            // The rim: brushed metal, tinted a little by the theme.
            Circle().fill(AngularGradient(colors: [Color(white: 0.58), Color(white: 0.2), Color(white: 0.66), Color(white: 0.17), Color(white: 0.6)], center: .center))
            Circle().fill(tint.opacity(failed ? 0.3 : 0.1))
            Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1)
            ForEach(0..<8, id: \.self) { i in
                Circle().fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.3)], center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.03))
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
                    .frame(width: size * 0.034, height: size * 0.034)
                    .offset(y: -(size / 2 - rim / 2)).rotationEffect(.degrees(Double(i) * 45 + 22.5))
            }
            // The glass: the game, with the ring that counts the launch inside the rim.
            ZStack {
                Circle().fill(.black)
                GameArtView(id: data.gameID, name: data.name, kind: .header).frame(width: size * 0.68, height: size * 0.68).clipShape(Circle())
                    .saturation(failed ? 0.2 : 1).opacity(failed ? 0.65 : 1)
                Circle().strokeBorder(.white.opacity(0.1), lineWidth: size * 0.03).padding(size * 0.035)
                Circle().trim(from: 0, to: failed ? 1 : max(0.02, data.progress)).rotation(.degrees(-90))
                    .stroke(failed ? AnyShapeStyle(Theme.bad) : AnyShapeStyle(Theme.accentGradient), style: StrokeStyle(lineWidth: size * 0.03, lineCap: .round))
                    .padding(size * 0.035)
                    .shadow(color: tint.opacity(0.85 * Theme.glowStrength), radius: 10)
                    .animation(.easeInOut(duration: 0.6), value: data.progress)
                if !failed { Spinner(size: size) }
                // A sheen across the glass.
                Circle().fill(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .topLeading, endPoint: .center)).blendMode(.screen).allowsHitTesting(false)
            }
            .padding(rim)
        }
        .frame(width: size, height: size)
        .overlay { if halloweenOn, !failed { HalloweenOrbitBat(size: size) } }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .shadow(color: tint.opacity(0.4 * Theme.glowStrength), radius: 34)
        .overlay(alignment: .bottomTrailing) {
            if failed {
                Image(systemName: "exclamationmark").font(.system(size: size * 0.12, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: size * 0.25, height: size * 0.25).background(Theme.bad, in: Circle()).overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 3))
                    .offset(x: size * 0.01, y: size * 0.01).transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) { if halloweenOn { HalloweenPumpkin(size: size * 0.22, face: .grin).rotationEffect(.degrees(8)).offset(x: size * 0.05, y: -size * 0.07) } }
        .padding(size * 0.02)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: failed)
    }

    /// A bright arc that circles the glass while the launch is working.
    private struct Spinner: View {
        let size: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
                let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360
                Circle().trim(from: 0, to: 0.08).stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: size * 0.012, lineCap: .round))
                    .rotationEffect(.degrees(angle)).padding(size * 0.095)
            }
        }
    }
}
