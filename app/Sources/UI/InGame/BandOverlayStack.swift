// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// The people in the call as one row of chips (picture and name), for the room between the controller's trigger columns on an iPad. With more than four people the names go and only the
/// pictures stay, so the row stays short; whoever is talking has the green ring either way.
struct DiscordCallRow: View {
    let members: [CallMember]
    var fontSize: CGFloat = 13
    var opacity: Double = 0.75
    /// The most people drawn: past this the rest are a "+N", so a big call never shrinks the numbers beside it.
    static let limit = 12

    /// The people drawn, in the call's own order: everyone talking is always among them, the rest fill what room is left.
    static func shown(_ members: [CallMember], limit: Int = DiscordCallRow.limit) -> (people: [CallMember], hidden: Int) {
        guard members.count > limit else { return (members, 0) }
        let speakers = members.filter(\.speaking).prefix(limit)
        var keep = Set(speakers.map(\.id))
        for m in members where keep.count < limit { keep.insert(m.id) }
        return (members.filter { keep.contains($0.id) }, members.count - keep.count)
    }

    var body: some View {
        let (people, hidden) = Self.shown(members)
        let names = members.count <= 4
        HStack(spacing: names ? 12 : 6) {
            ForEach(people) { member in
                HStack(spacing: 5) {
                    DiscordAvatar(member: member, diameter: fontSize * 2)
                    if names {
                        Text(member.name).font(.system(size: fontSize, weight: member.speaking ? .bold : .medium)).foregroundStyle(.white).lineLimit(1).frame(maxWidth: fontSize * 9)
                    }
                }
                .opacity(member.speaking ? 1 : 0.78)
            }
            if hidden > 0 { Text("+\(hidden)").font(.system(size: fontSize, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(.white.opacity(0.8)) }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(opacity * 0.82)))
        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: members)
    }
}

/// What sits in the room between the trigger columns while the game picture is up at the top of an iPad: the performance numbers, and under them the people in the call. Each is optional;
/// what is there is centred, so the stack grows outward from its middle as numbers or people are added, and it shrinks to fit when the room is small. It never takes touches.
struct BandOverlayStack: View {
    let room: CGSize
    var perf: PerfCardView?
    var members: [CallMember] = []
    var fontSize: CGFloat = 13
    var opacity: Double = 0.75
    @State private var natural = CGSize.zero

    var body: some View {
        let known = natural.width > 0 && natural.height > 0
        let scale = known ? min(1, room.width / natural.width, room.height / natural.height) : 1
        VStack(spacing: 6) {
            if let perf { perf.fixedSize() }
            if !members.isEmpty { DiscordCallRow(members: members, fontSize: fontSize, opacity: opacity).fixedSize() }
        }
        .fixedSize()
        .background(GeometryReader { proxy in
            Color.clear.onAppear { natural = proxy.size }.onChange(of: proxy.size) { _, new in natural = new }
        })
        .scaleEffect(scale, anchor: .center)
        .frame(width: room.width, height: room.height, alignment: .center)
        .allowsHitTesting(false)
    }
}


/// Where a layout of the person's own puts an overlay: the middle of it as fractions of the room the controls use, and how much bigger or smaller than usual it is drawn.
struct OverlayPlacement: Equatable {
    var x: Double, y: Double, scale: Double = 1
}

/// Draws its content centred on a point of the room (given as fractions), kept entirely inside the room, as big as the placement says. The content grows outward from that point.
struct PlacedAtFraction<Content: View>: View {
    let at: OverlayPlacement
    let room: CGSize
    @ViewBuilder var content: Content
    @State private var size = CGSize.zero

    var body: some View {
        let w = size.width * at.scale, h = size.height * at.scale
        content
            .fixedSize()
            .background(GeometryReader { proxy in
                Color.clear.onAppear { size = proxy.size }.onChange(of: proxy.size) { _, new in size = new }
            })
            .scaleEffect(at.scale)
            .position(x: min(max(at.x * room.width, w / 2), max(w / 2, room.width - w / 2)), y: min(max(at.y * room.height, h / 2), max(h / 2, room.height - h / 2)))
            .frame(width: room.width, height: room.height)
    }
}
