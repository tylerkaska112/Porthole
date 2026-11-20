import SwiftUI

/// The Discord message banner over something that looks like a game: a mention in a server, a direct message, several messages joined, and one with the text hidden.
struct DiscordBannerDemo: View {
    private func banner(_ conversation: DiscordConversation, _ who: String, _ text: String, count: Int = 1) -> DiscordBanner {
        DiscordBanner(conversation: conversation, author: DiscordUser(id: who, username: who.lowercased(), globalName: who), text: text, count: count)
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.25, blue: 0.14), Color(red: 0.35, green: 0.3, blue: 0.2), Color(red: 0.1, green: 0.1, blue: 0.15)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 10) {
                DiscordBannerCard(banner: banner(DiscordConversation(id: "1", title: "#general", place: "Porthole Testers"), "Alex", "@You are you free tonight? We are doing the big factory run and need one more person who can build trains."), lifetime: 6)
                DiscordBannerCard(banner: banner(DiscordConversation(id: "2", title: "Sam", place: nil), "Sam", "hey, did the new build fix the crash?"))
                DiscordBannerCard(banner: banner(DiscordConversation(id: "3", title: "#bug-reports", place: "Porthole Testers"), "Jo", "x", count: 4))
                DiscordBannerCard(banner: banner(DiscordConversation(id: "4", title: "Robin", place: nil), "Robin", "New message"))
                DiscordCallBannerCard(call: DiscordIncomingCall(channelID: "5", title: "Alex", caller: DiscordUser(id: "2", username: "alex", globalName: "Alex"), isGroup: false))
                DiscordCallBannerCard(call: DiscordIncomingCall(channelID: "6", title: "Alex, Sam and 2 more", caller: nil, isGroup: true))
            }
            .frame(maxWidth: 440).padding(.horizontal, 12).padding(.top, 8)
        }
    }
}
