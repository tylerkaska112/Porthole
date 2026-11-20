// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// What an achievement pop-up looks like: the achievement's picture in a gold frame, "Achievement unlocked", its name and what it asks for.
struct AchievementToastCard: View {
    let name: String
    let detail: String
    let icon: URL?
    var lifetime: TimeInterval?

    var body: some View {
        HStack(spacing: 13) {
            AsyncImage(url: icon) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { LinearGradient(colors: [BannerColors.gold.opacity(0.35), BannerColors.gold.opacity(0.12)], startPoint: .top, endPoint: .bottom).overlay { Image(systemName: "trophy.fill").font(.system(size: 22)).foregroundStyle(BannerColors.gold) } }
            }
            .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(LinearGradient(colors: [BannerColors.gold, BannerColors.gold.opacity(0.35)], startPoint: .top, endPoint: .bottom), lineWidth: 2))
            .shadow(color: BannerColors.gold.opacity(0.45), radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Label("ACHIEVEMENT UNLOCKED", systemImage: "trophy.fill").font(.system(size: 10.5, weight: .heavy, design: .rounded)).tracking(0.8).foregroundStyle(BannerColors.gold)
                Text(name).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.78)).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .bannerChrome(accent: BannerColors.gold, lifetime: lifetime)
    }
}
