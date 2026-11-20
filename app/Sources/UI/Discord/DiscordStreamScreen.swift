// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import AVFoundation
import SwiftUI

/// Somebody's Go Live, full screen (experimental). The picture is drawn by a display layer that decodes the H.264 itself; this screen only says what is happening and offers Stop watching
/// and the sound.
struct DiscordPictureView: UIViewRepresentable {
    let sink: DiscordPictureSink

    final class Host: UIView { override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self } }

    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.backgroundColor = .black
        if let layer = host.layer as? AVSampleBufferDisplayLayer {
            layer.videoGravity = .resizeAspect
            layer.flushAndRemoveImage()
            sink.attach(layer)
        }
        return host
    }

    func updateUIView(_ host: Host, context: Context) {}

    static func dismantleUIView(_ host: Host, coordinator: ()) { }
}

struct DiscordStreamScreen: View {
    @ObservedObject private var discord = DiscordSession.shared
    @State private var scope = FocusScope()
    @State private var muted = false
    var onClose: () -> Void

    private var streamer: String { discord.callMembers.first { $0.id == discord.watchingID }?.name ?? "the stream" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DiscordPictureView(sink: discord.viewer.sink).ignoresSafeArea()
            status
            VStack {
                HStack(spacing: 12) {
                    Text(discord.watchState == .watching ? "Watching \(streamer)" : streamer)
                        .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 14).frame(height: 40).background(.black.opacity(0.55), in: Capsule())
                    Spacer()
                    PillButton(id: "sw-pacing", title: discord.watchPacing.title, symbol: "waveform.path") { discord.cycleWatchPacing() }
                    PillButton(id: "sw-sound", title: muted ? "Sound off" : "Sound on", symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                        muted.toggle(); discord.viewer.muted = muted
                    }
                    PillButton(id: "sw-close", title: "Stop watching", symbol: "xmark", style: .danger) { onClose() }
                }
                .padding(.horizontal, 16).padding(.top, 10)
                Spacer()
            }
        }
        .navScope(scope)
        .onAppear { scope.defaultFocus = "sw-close"; scope.focused = "sw-close"; scope.onBack = { onClose() }; muted = discord.viewer.muted }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    @ViewBuilder private var status: some View {
        switch discord.watchState {
        case .connecting, .waiting:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text(discord.watchState == .connecting ? "Connecting to the stream" : "Connected. Waiting for the first picture")
                    .font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Text("This can take a few seconds.").font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
            .padding(24)
        case .failed(let why):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(Theme.warn)
                Text(why).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 420)
                if let id = discord.watchingID, discord.canWatch(id) {
                    PillButton(id: "sw-retry", title: "Try again", symbol: "arrow.clockwise", style: .primary) { discord.watchStream(of: id) }
                }
            }
            .padding(24)
        case .idle, .watching:
            EmptyView()
        }
    }
}
