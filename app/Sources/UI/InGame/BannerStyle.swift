// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The look every pop-up over a game shares (Discord messages, calls, achievements): a soft dark glass card with a colour of its own on the picture side, a light edge, and a thin
/// line along the bottom that drains while the pop-up stays. It is a gradient with some see-through, not a blur: a blur would make the game's own picture cost more to draw.
struct BannerChrome: ViewModifier {
    var accent: Color
    /// How long the pop-up stays, in seconds: the line drains over that time. nil keeps a card without the line (a call rings until it is answered).
    var lifetime: TimeInterval?
    @State private var left: CGFloat = 1

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        content
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, lifetime == nil ? 12 : 17)
            .background(
                ZStack {
                    shape.fill(LinearGradient(colors: [Color(red: 0.14, green: 0.15, blue: 0.22).opacity(0.82), Color(red: 0.05, green: 0.05, blue: 0.09).opacity(0.76)], startPoint: .top, endPoint: .bottom))
                    shape.fill(LinearGradient(colors: [accent.opacity(0.26), accent.opacity(0)], startPoint: .leading, endPoint: UnitPoint(x: 0.6, y: 0.5)))
                }
            )
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.32), accent.opacity(0.5), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .overlay(alignment: .bottom) {
                if lifetime != nil {
                    GeometryReader { geo in
                        Capsule().fill(accent.opacity(0.9)).frame(width: max(0, geo.size.width) * left, height: 3)
                    }
                    .frame(height: 3).padding(.horizontal, 20).padding(.bottom, 7)
                }
            }
            .shadow(color: accent.opacity(0.30), radius: 14, y: 5)
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
            .onAppear { if let lifetime { withAnimation(.linear(duration: lifetime)) { left = 0 } } }
    }
}

extension View {
    func bannerChrome(accent: Color, lifetime: TimeInterval? = nil) -> some View { modifier(BannerChrome(accent: accent, lifetime: lifetime)) }
}

enum BannerColors {
    /// Discord's blue-violet, for messages.
    static let discord = Color(red: 0.40, green: 0.45, blue: 1.0)
    static let call = Color(red: 0.22, green: 0.78, blue: 0.45)
    static let decline = Color(red: 0.90, green: 0.27, blue: 0.32)
    static let gold = Color(red: 1.0, green: 0.78, blue: 0.25)
}
