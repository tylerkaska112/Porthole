// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A guide as a sheet: one step at a time with a drawing of the screen (or a symbol), a heading and a few words, a button that takes you there when the step has one, and Back / Next.
/// A controller can answer it (A is Next, B goes back or closes).
struct GuideSheet: View {
    let guide: Guide
    /// Does what a step's button says (open Add a game, a store, a settings page). Nothing happens when a guide is shown somewhere that cannot.
    var perform: (GuideAction) -> Void = { _ in }
    /// Whether the last step offers the interactive tutorial. Only where `perform` can really start it.
    var offersTutorial = false
    @State private var index: Int
    @State private var scope = FocusScope()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var vSize

    init(guide: Guide, startAt: Int = 0, offersTutorial: Bool = false, perform: @escaping (GuideAction) -> Void = { _ in }) {
        self.guide = guide; self.perform = perform; self.offersTutorial = offersTutorial
        _index = State(initialValue: startAt)
    }

    private var step: GuideStep { guide.steps[min(index, guide.steps.count - 1)] }
    private var last: Bool { index >= guide.steps.count - 1 }
    private var compact: Bool { vSize == .compact }

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(spacing: 0) {
                HStack {
                    Text(guide.title.uppercased()).font(.footnote.weight(.bold)).foregroundStyle(Theme.textDim).tracking(0.6)
                    Spacer()
                    if guide.steps.count > 1 { Text("\(index + 1) of \(guide.steps.count)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.textDim) }
                }
                .padding(.horizontal, 24).padding(.top, 22)

                ScrollView {
                    Group {
                        if compact && step.art != nil { HStack(spacing: 24) { picture; text } } else { VStack(spacing: 14) { picture; text } }
                    }
                    .padding(.horizontal, 28).padding(.top, 14).frame(maxWidth: compact ? 900 : 560).frame(maxWidth: .infinity)
                    .id(index)
                    .transition(.opacity)
                }

                if guide.steps.count > 1 {
                    HStack(spacing: 7) {
                        ForEach(guide.steps.indices, id: \.self) { i in
                            Circle().fill(i == index ? Theme.accent : Theme.textDim.opacity(0.35)).frame(width: 7, height: 7)
                        }
                    }
                    .padding(.vertical, 10).accessibilityHidden(true)
                }

                HStack(spacing: 12) {
                    if index > 0 { PillButton(id: "guide-back", title: "Back", symbol: "chevron.left") { go(-1) } }
                    PillButton(id: "guide-next", title: last ? "Got it" : "Next", symbol: last ? "checkmark" : "chevron.right", style: .primary) {
                        if last { dismiss() } else { go(1) }
                    }
                }
                Button {
                    GuideCenter.shared.enabled = false
                    dismiss()
                } label: {
                    Text("Do not show tips").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textDim).padding(.vertical, 12).padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                .focusTarget("guide-off", radius: 14, scale: 1.04) { GuideCenter.shared.enabled = false; dismiss() }
                .accessibilityHint("Turns tips off. You can turn them on again in Settings, App.")
                .padding(.bottom, 10)
            }
        }
        .navScope(scope)
        .onAppear {
            scope.defaultFocus = "guide-next"; scope.focused = "guide-next"
            scope.onBack = { if index > 0 { go(-1) } else { dismiss() } }
        }
        .presentationDetents(compact ? [.large] : [.fraction(0.82), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
    }

    @ViewBuilder private var picture: some View {
        if let art = step.art { GuideArtView(art: art).frame(maxWidth: 440) }
        else { IconTile(symbol: step.symbol, size: 64).padding(.top, 8) }
    }

    private var text: some View {
        VStack(spacing: 12) {
            if step.art != nil { Label(step.title, systemImage: step.symbol).labelStyle(TitleIconLabelStyle()) }
            else { Text(step.title).font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text).multilineTextAlignment(.center) }
            Text(step.text).font(.body).foregroundStyle(Theme.text.opacity(0.88)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let action = step.action {
                PillButton(id: "guide-action", title: action.title, symbol: action.symbol) { perform(action) }.padding(.top, 4)
            }
            // The last step of a screen's guide offers the interactive version: the same screen, with the real buttons pointed at.
            if last, offersTutorial, let id = TutorialLibrary.shared.tutorialID(forGuide: guide.id) {
                PillButton(id: "guide-tutorial", title: "Walk me through it", symbol: "hand.point.up.left.fill", style: .primary) { perform(.tutorial(id)) }.padding(.top, 4)
            }
        }
    }

    private func go(_ delta: Int) {
        withAnimation(.easeInOut(duration: 0.2)) { index = max(0, min(guide.steps.count - 1, index + delta)) }
        scope.focused = "guide-next"
    }
}

/// The heading of a step that has a drawing: a small symbol beside the words.
private struct TitleIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon.font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.accent)
            configuration.title.font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
        }
    }
}

/// Shows a guide by itself the first time the screen it is attached to appears, from inside that screen: for sheets, which the app frame's own guide sheet cannot appear over.
struct LocalGuideModifier: ViewModifier {
    let id: String
    @State private var guide: Guide?

    func body(content: Content) -> some View {
        content
            .sheet(item: $guide) { GuideSheet(guide: $0) }
            .task {
                let center = GuideCenter.shared
                guard center.enabled, !center.hasSeen(id), let g = GuideCatalog.guide(id) else { return }
                try? await Task.sleep(for: .milliseconds(900))
                guard center.enabled, !center.hasSeen(id) else { return }
                center.markSeen(id)
                guide = g
            }
    }
}

extension View {
    func localGuide(_ id: String) -> some View { modifier(LocalGuideModifier(id: id)) }
}
