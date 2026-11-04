import SwiftUI

/// The Halloween props on their own and on a card, over the real backdrop (bats, moon, embers), to look at them in the simulator.
struct PropsDemo: View {
    var body: some View {
        ZStack {
            AmbientBackdrop()
            VStack(alignment: .leading, spacing: 18) {
                if ThemeStore.shared.palette.decor == .thanksgiving {
                    HStack(alignment: .bottom, spacing: 26) {
                        HalloweenPumpkin(size: 84, face: .plain)
                        HarvestTurkey(size: 96)
                        HarvestAcorn(size: 40)
                        HarvestPatch(height: 84)
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 26) {
                        HalloweenPumpkin(size: 84, face: .grin)
                        HalloweenPumpkin(size: 84, face: .cute)
                        HalloweenPumpkin(size: 84, face: .angry)
                        HalloweenGhost(size: 64)
                        HalloweenPatch(height: 84)
                    }
                }
                HStack(spacing: 14) {
                    Circle().fill(Theme.accent).frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Steam").font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                        Text("486 games · 2 installed").font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, 16).padding(.vertical, 14).frame(minHeight: 76)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                .festiveCardSitter()
                .frame(maxWidth: 520)
            }
            .padding(40)
        }
    }
}
