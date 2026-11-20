// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// A picture from a chat, full screen: pinch to zoom, drag it while zoomed, double-tap to go back to fitting the screen. Close with the button, B on a controller, or Escape.
struct DiscordImageViewer: View {
    let url: URL
    var name = ""
    var close: () -> Void = {}

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var scope = FocusScope()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                        .scaleEffect(scale).offset(offset)
                        .gesture(MagnifyGesture()
                            .onChanged { scale = min(max(1, baseScale * $0.magnification), 6) }
                            .onEnded { _ in baseScale = scale; if scale <= 1 { offset = .zero; lastOffset = .zero } })
                        .simultaneousGesture(DragGesture().onChanged { v in
                            guard scale > 1 else { return }
                            offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                        }.onEnded { _ in lastOffset = offset })
                        .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { scale = 1; baseScale = 1; offset = .zero; lastOffset = .zero } }
                case .failure:
                    VStack(spacing: 10) { Image(systemName: "photo").font(.system(size: 44)); Text("This picture could not be loaded").font(.subheadline) }.foregroundStyle(.white.opacity(0.7))
                default:
                    ProgressView().tint(.white)
                }
            }
            .padding(8)
            VStack {
                HStack(spacing: 12) {
                    PillButton(id: "iv-close", title: "Close", symbol: "xmark") { close() }
                    Spacer()
                    if !name.isEmpty { Text(name).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44).background(Circle().fill(Color.white.opacity(0.16))) }
                        .accessibilityLabel("Share the picture's address")
                }
                .padding(.horizontal, 20).padding(.top, 14)
                Spacer()
            }
        }
        .navScope(scope)
        .onAppear { scope.defaultFocus = "iv-close"; scope.focused = "iv-close"; scope.onBack = { close() } }
        .preferredColorScheme(.dark)
    }
}
