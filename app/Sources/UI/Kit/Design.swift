// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

// Building blocks the redesigned screens share, so every page looks and behaves the same on iPhone and iPad.

/// A rounded coloured square with a symbol, like the icons in iOS Settings.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A large tappable choice: icon, title, one line of explanation.
struct ActionCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    var tint: Color = Theme.accent
    var prominent = false
    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, tint: prominent ? .white.opacity(0.25) : tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(prominent ? .white : Theme.text)
                Text(subtitle).font(.subheadline).foregroundStyle(prominent ? .white.opacity(0.85) : Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(prominent ? .white.opacity(0.7) : Theme.textDim)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(GlassFill.panel), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A titled card on a scrolling page: heading above, the content inside a panel, an optional explanation below.
struct PageSection<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textDim).textCase(.uppercase).padding(.horizontal, 4) }
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(GlassFill.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let footer { Text(footer).font(.footnote).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4) }
        }
    }
}

/// A label on the left and a value on the right.
struct InfoRow: View {
    let title: String
    let value: String
    var monospaced = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Theme.text)
            Spacer(minLength: 12)
            Text(value).font(monospaced ? .footnote.monospaced() : .body).foregroundStyle(Theme.textDim).multilineTextAlignment(.trailing)
        }
    }
}

/// A small outlined label ("64-bit", "Steam").
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = Theme.textDim
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2.weight(.bold)) }
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

extension View {
    /// Keeps content a comfortable reading width on iPad and centres it, instead of stretching across the whole screen.
    func readableWidth(_ maximum: CGFloat = 820) -> some View {
        frame(maxWidth: maximum).frame(maxWidth: .infinity)
    }
}

/// How many grid columns fit: cards stay a good size from a small iPhone to a 13-inch iPad.
enum Layout {
    static let cardGrid = [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 18, alignment: .top)]
    static let panelGrid = [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)]
}
