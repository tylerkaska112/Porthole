// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The small drawings that go with a guide step: a simplified picture of the screen, with the part the step talks about ringed.
enum GuideArt: Hashable {
    case home, addGame, notices
    case stores, storesLists
    case reports, settings
    case gamePage, gameRows
    case addSources
    case gameMenu
}

struct GuideArtView: View {
    let art: GuideArt
    @State private var pulse = false

    /// The drawings are laid out on a fixed canvas and scaled to the room there is.
    private static let canvas = CGSize(width: 360, height: 200)

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / Self.canvas.width, geo.size.height / Self.canvas.height)
            drawing
                .frame(width: Self.canvas.width, height: Self.canvas.height)
                .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                .scaleEffect(scale)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(Self.canvas.width / Self.canvas.height, contentMode: .fit)
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true } }
        .accessibilityHidden(true)
    }

    // MARK: Pieces

    private func ring(_ on: Bool, radius: CGFloat = 10) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.accent, lineWidth: 3).padding(-4).scaleEffect(pulse ? 1.05 : 1).opacity(on ? 1 : 0)
    }

    private func bar(_ selected: Int) -> some View {
        HStack(spacing: 14) {
            Circle().fill(Theme.accent.opacity(0.8)).frame(width: 14, height: 14)
            ForEach(Array(["Home", "Stores", "Reports", "Settings"].enumerated()), id: \.offset) { i, t in
                Text(t).font(.system(size: 10, weight: i == selected ? .heavy : .semibold, design: .rounded)).foregroundStyle(i == selected ? Theme.text : Theme.textDim)
                    .overlay(alignment: .bottom) { if i == selected { Capsule().fill(Theme.accent).frame(height: 2).offset(y: 5) } }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func line(_ w: CGFloat, _ h: CGFloat = 6, _ o: Double = 0.2) -> some View { Capsule().fill(.white.opacity(o)).frame(width: w, height: h) }

    private func pill(_ text: String, prominent: Bool = true, ringed: Bool = false) -> some View {
        Text(text).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(prominent ? Color.white : Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.12)), in: Capsule())
            .overlay { ring(ringed, radius: 14) }
    }

    private func tile(_ symbol: String, _ tint: Color, size: CGFloat = 22) -> some View { IconTile(symbol: symbol, tint: tint, size: size) }

    private func gameCard(w: CGFloat, h: CGFloat, ringed: Bool = false, play: Bool = false, ringPlay: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: w, height: h)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    line(w * 0.5, 7, 0.5)
                    line(w * 0.3, 5, 0.25)
                    if play { pill("Play", ringed: ringPlay).padding(.top, 3) }
                }
                .padding(10)
            }
            .overlay { ring(ringed, radius: 14) }
    }

    private func row(_ symbol: String, _ tint: Color, _ title: String, value: String? = nil, ringed: Bool = false) -> some View {
        HStack(spacing: 8) {
            tile(symbol, tint, size: 20)
            Text(title).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
            Spacer(minLength: 4)
            if let value { Text(value).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textDim) }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { ring(ringed, radius: 11) }
    }

    // MARK: Drawings

    @ViewBuilder private var drawing: some View {
        switch art {
        case .home:
            VStack(alignment: .leading, spacing: 8) {
                bar(0)
                HStack(alignment: .top, spacing: 10) {
                    gameCard(w: 190, h: 112, ringed: false, play: true, ringPlay: true)
                    VStack(spacing: 8) { gameCard(w: 120, h: 52); gameCard(w: 120, h: 52, ringed: true) }
                }
                .padding(.horizontal, 14)
                Text("Tap a card to open that game's page").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textDim).padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
        case .addGame:
            VStack(alignment: .leading, spacing: 8) {
                bar(0)
                HStack(spacing: 10) {
                    gameCard(w: 100, h: 70); gameCard(w: 100, h: 70)
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .frame(width: 100, height: 70)
                        .overlay(VStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 16, weight: .heavy)); Text("Add a game").font(.system(size: 9, weight: .bold, design: .rounded)) }.foregroundStyle(Theme.accent))
                        .overlay { ring(true, radius: 14) }
                }
                .padding(.horizontal, 14).padding(.top, 8)
                Spacer(minLength: 0)
            }
        case .notices:
            VStack(alignment: .leading, spacing: 8) {
                bar(0)
                VStack(spacing: 7) {
                    notice("hourglass", "Waiting for JIT", "Cancel", ringed: false)
                    notice("arrow.down.circle.fill", "An update is ready", "Install", ringed: true)
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 0)
            }
        case .stores:
            VStack(alignment: .leading, spacing: 8) {
                bar(1)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    store("S", .blue, "Steam", ringed: true); store("E", .indigo, "Epic Games"); store("G", .purple, "GOG"); store("i", .red, "itch.io")
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 0)
            }
        case .storesLists:
            VStack(alignment: .leading, spacing: 8) {
                bar(1)
                VStack(spacing: 7) {
                    row("square.grid.2x2.fill", .blue, "All games", value: "every library", ringed: true)
                    row("arrow.down.circle.fill", .green, "Downloads", value: "2 in progress")
                    row("checkmark.circle.fill", Theme.accent, "Steam", value: "signed in")
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 0)
            }
        case .reports:
            VStack(alignment: .leading, spacing: 8) {
                bar(2)
                VStack(spacing: 7) {
                    report("Factorio", "12 reports", "Works great", .green, ringed: true)
                    report("Another game", "5 reports", "Playable", .orange)
                    report("A third game", "2 reports", "Doesn't start", .red)
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 0)
            }
        case .settings:
            VStack(alignment: .leading, spacing: 8) {
                bar(3)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 7) {
                    row("gamecontroller.fill", .blue, "Play"); row("storefront.fill", .indigo, "Stores")
                    row("bolt.horizontal.fill", .green, "JIT and connection"); row("externaldrive.fill", .teal, "Saves")
                    row("internaldrive.fill", .orange, "Storage"); row("arrow.down.circle.fill", .mint, "Updates")
                    row("wrench.and.screwdriver.fill", .gray, "Advanced"); row("exclamationmark.bubble.fill", .red, "Report a problem")
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 0)
            }
        case .gamePage:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 96, height: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        line(120, 9, 0.6); line(80, 6, 0.25)
                        pill("Play", ringed: true).padding(.top, 2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 18)
                row("rectangle.expand.vertical", .blue, "Resolution", value: "Default")
                    .padding(.horizontal, 14)
                row("bolt.fill", .orange, "Power mode", value: "Default").padding(.horizontal, 14)
                Spacer(minLength: 0)
            }
        case .gameRows:
            VStack(alignment: .leading, spacing: 7) {
                Text("PLAY").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textDim).padding(.horizontal, 16).padding(.top, 14)
                row("rectangle.expand.vertical", .blue, "Resolution", value: "Default", ringed: false).padding(.horizontal, 14)
                row("bolt.fill", .orange, "Power mode", value: "Performance", ringed: true).padding(.horizontal, 14)
                row("internaldrive.fill", .gray, "Swap", value: "Off").padding(.horizontal, 14)
                Text("A row that says Default follows Settings").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textDim).padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
        case .addSources:
            VStack(spacing: 6) {
                row("folder.badge.plus", Theme.accent, "Import a game folder", value: "From Files")
                row("arrow.down.circle.fill", .blue, "Download from Steam", value: "Games you own", ringed: true)
                row("arrow.down.circle.fill", .indigo, "Download from Epic Games")
                row("arrow.down.circle.fill", .purple, "Download from GOG")
                row("arrow.down.circle.fill", .red, "Download from itch.io")
                row("shippingbox.fill", .orange, "Run a Windows installer", value: "Disc or setup file")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        case .gameMenu:
            HStack(spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Menu").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        pill("Performance", prominent: true, ringed: true); pill("Controls", prominent: false); pill("Game", prominent: false)
                    }
                    row("bolt.fill", .orange, "Power", value: "Balanced")
                    row("leaf.fill", .green, "Eco mode", value: "Off")
                    row("speedometer", Theme.accent, "Show overlay", value: "Off")
                }
                .padding(12).frame(width: 250, height: 200, alignment: .topLeading).background(Color(white: 0.12))
            }
        }
    }

    private func notice(_ symbol: String, _ title: String, _ action: String, ringed: Bool) -> some View {
        HStack(spacing: 8) {
            tile(symbol, .orange, size: 24)
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(Theme.text); line(80, 5, 0.25) }
            Spacer()
            pill(action, prominent: false, ringed: ringed)
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textDim)
        }
        .padding(8).background(Theme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func store(_ letter: String, _ tint: Color, _ name: String, ringed: Bool = false) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint).frame(width: 30, height: 30).overlay(Text(letter).font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) { Text(name).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(Theme.text); line(54, 5, 0.22) }
            Spacer(minLength: 0)
        }
        .padding(9).background(Theme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay { ring(ringed, radius: 13) }
    }

    private func report(_ name: String, _ count: String, _ verdict: String, _ tint: Color, ringed: Bool = false) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) { Text(name).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(Theme.text); Text(count).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textDim) }
            Spacer()
            Text(verdict).font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(tint).padding(.horizontal, 9).padding(.vertical, 4).background(tint.opacity(0.18), in: Capsule())
        }
        .padding(.horizontal, 10).padding(.vertical, 7).background(Theme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay { ring(ringed, radius: 13) }
    }
}
