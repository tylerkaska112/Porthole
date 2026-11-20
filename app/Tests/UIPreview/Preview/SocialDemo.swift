import SwiftUI

/// The Social tab's shape (the real one needs the app's stores): the Discord / Steam switch over Discord itself; held sideways the switch moves into the rail.
struct SocialDemo: View {
    @Environment(\.verticalSizeClass) private var vertical
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vertical != .compact {
                HStack { SegmentedPills(options: [.init(id: "discord", title: "Discord"), .init(id: "steam", title: "Steam")], selection: "discord") { _ in }; Spacer() }
                    .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 10)
            }
            DiscordBrowser(data: DiscordDemo.data, actions: DiscordBrowserActions(otherSection: vertical == .compact ? (title: "Steam", go: {}) : nil), embedded: true)
        }
    }
}
