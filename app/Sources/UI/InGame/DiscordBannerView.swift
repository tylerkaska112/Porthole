// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The banner for a Discord message: slides in from the top over the game, for a few seconds. Tap it to open the in-game menu on that conversation and answer; swipe it up
/// to send it away. It is the only part of the overlay that takes touches, and only while it is showing and only inside its own card.
struct DiscordBannerView: View {
    @ObservedObject private var notifier = DiscordNotifier.shared

    var body: some View {
        VStack(spacing: 0) {
            if notifier.callBannerShowing, let call = notifier.incomingCall {
                DiscordCallBannerCard(call: call, join: { notifier.answerCall() }, decline: { notifier.declineCall() })
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id("call-\(call.channelID)")
            } else if let banner = notifier.current {
                DiscordBannerCard(banner: banner, lifetime: DiscordNotifier.showFor, open: { notifier.open(banner) }, dismiss: { notifier.dismiss() })
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(banner.id)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: notifier.current?.id)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: notifier.callBannerShowing)
    }
}
