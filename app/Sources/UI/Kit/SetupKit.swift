// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// Pieces of the first-run guide, drawn from plain values so the UI preview app can show them.

/// Where you are in the numbered steps: a circle for each, joined by a line, with a check on the ones that are done and the step's name under it.
struct SetupStepper: View {
    let names: [String]
    /// 1-based position of the page.
    let current: Int
    let done: [Bool]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                let number = index + 1
                if index > 0 {
                    Capsule().fill(number <= current ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh)).frame(height: 3).frame(maxWidth: .infinity).padding(.top, 14)
                }
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(done[index] ? AnyShapeStyle(Theme.good) : number == current ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh))
                        if done[index] { Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(.black.opacity(0.8)) }
                        else { Text("\(number)").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(number == current ? Theme.onAccent : Theme.textDim) }
                    }
                    .frame(width: 30, height: 30)
                    .shadow(color: number == current ? Theme.accent.opacity(0.6 * Theme.glowStrength) : .clear, radius: 8)
                    Text(name).font(.system(size: 12, weight: number == current ? .bold : .medium, design: .rounded)).foregroundStyle(number == current ? Theme.text : Theme.textDim)
                        .lineLimit(1).fixedSize()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(number), \(name)\(done[index] ? ", done" : "")")
            }
        }
    }
}

/// The first page's picture: the brand porthole with a soft glow, the welcome and what to expect.
struct SetupWelcomeHero: View {
    var compact = false

    var body: some View {
        if compact {
            HStack(spacing: 14) {
                PortholeMark(size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Porthole").font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(Theme.text)
                    Text("Three quick steps. Stop any time.").font(.subheadline).foregroundStyle(Theme.textDim)
                }
            }
        } else {
            VStack(spacing: 10) {
                PortholeMark(size: 128).shadow(color: Theme.accent.opacity(0.55 * Theme.glowStrength), radius: 30)
                Text("Welcome to Porthole").font(.system(size: 34, weight: .black, design: .rounded)).foregroundStyle(Theme.text)
                Text("Windows games on your iPhone and iPad.\nThree quick steps, and you can stop any time.").font(.system(size: 16, design: .rounded)).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
    }
}

/// One of the three steps on the welcome page: a big number, what it is, how long it takes, and whether it is needed.
struct SetupStepCard: View {
    let id: AnyHashable
    let number: Int
    let symbol: String
    let title: String
    let subtitle: String
    let tag: String
    var tagGood = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.16))
                Image(systemName: symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.accent)
            }
            .frame(width: 48, height: 48)
            .overlay(alignment: .topLeading) {
                Text("\(number)").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(Theme.onAccent)
                    .frame(width: 20, height: 20).background(Theme.accentGradient, in: Circle()).offset(x: -4, y: -4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                Text(subtitle).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(tag).font(.caption2.weight(.bold)).foregroundStyle(tagGood ? Theme.good : Theme.textDim)
                .padding(.horizontal, 8).padding(.vertical, 3).background((tagGood ? Theme.good : Theme.textDim).opacity(0.15), in: Capsule())
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .focusTarget(id, radius: 18, scale: 1.012, action: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// One store on the "Add your games" page: its logo, whether you are signed in, and the button for it.
struct StoreSignInRow: View {
    let id: AnyHashable
    let store: GameStore
    let signedIn: Bool
    let info: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                StoreBadgeBacked(store: store, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.title).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(signedIn ? Theme.good : Theme.textDim.opacity(0.6)).frame(width: 7, height: 7)
                        Text(signedIn ? "Signed in" : "Not signed in").font(.footnote).foregroundStyle(Theme.textDim)
                    }
                }
                Spacer(minLength: 8)
                Text(signedIn ? "Open library" : "Sign in").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(signedIn ? Theme.text : Theme.onAccent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(signedIn ? AnyShapeStyle(Theme.panelHigh) : AnyShapeStyle(Theme.accentGradient), in: Capsule())
            }
            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8).frame(minHeight: 58)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            InfoButton(id: "\(id)-info", title: store.title, text: info)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .focusTarget(id, radius: 16, scale: 1.012, action: action)
    }
}
