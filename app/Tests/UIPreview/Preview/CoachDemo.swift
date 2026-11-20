import SwiftUI

/// A small app (the real tab bar, real rows) with a tutorial running on it, to see and try the coach marks: tap what the tutorial points at and it moves on.
@MainActor @Observable
final class CoachDemoState {
    var tab = "home"
    var sheet = false
    var autoBackup = false
}

struct CoachDemo: View {
    @State private var state = CoachDemoState()
    @State private var scope = FocusScope()
    private let tabs = [ShellTab(id: "home", title: "Home", symbol: "house.fill"), ShellTab(id: "stores", title: "Stores", symbol: "square.grid.2x2.fill"),
                        ShellTab(id: "reports", title: "Reports", symbol: "checkmark.seal.fill"), ShellTab(id: "social", title: "Social", symbol: "bubble.left.and.bubble.right.fill"),
                        ShellTab(id: "settings", title: "Settings", symbol: "gearshape.fill")]

    var body: some View {
        AppShell(tabs: tabs, selection: Binding(get: { state.tab }, set: { state.tab = $0 }), showHints: false, onHelp: {}) {
            FocusScroll {
                VStack(alignment: .leading, spacing: 14) {
                    switch state.tab {
                    case "stores":
                        Text("Stores").font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                        SettingsGroup(title: "Launchers") {
                            ActionRow(id: "store-steam", symbol: "arrow.down.circle.fill", title: "Steam", subtitle: "Not signed in") { state.sheet = true }
                            ActionRow(id: "store-epic", symbol: "bag.fill", title: "Epic Games", subtitle: "Not signed in") {}
                        }
                    case "settings":
                        Text("Settings").font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                        SettingsGroup(title: "Saves") {
                            ToggleRow(id: "sv-auto", symbol: "clock.arrow.circlepath", title: "Back up after each game", info: "Zips your saves when a game ends.",
                                      isOn: Binding(get: { state.autoBackup }, set: { state.autoBackup = $0 }))
                        }
                    default:
                        Text("Home").font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                        SettingsGroup(title: "Your games") {
                            ActionRow(id: "add-game", symbol: "plus.circle.fill", title: "Add a game", subtitle: "From a store or Files") {}
                            ActionRow(id: "game-1", symbol: "gamecontroller.fill", title: "Factorio", subtitle: "Ready to play") {}
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
        }
        .navScope(scope)
        .sheet(isPresented: $state.sheet) {
            VStack(spacing: 16) {
                Text("Sign in to Steam").font(.title2.bold())
                Button("Sign in") { state.sheet = false }.coachTarget("steam-signin").buttonStyle(.borderedProminent)
            }.padding(40).presentationDetents([.medium])
        }
        .onAppear {
            Coach.shared.onEvent = { print($0) }
            Coach.shared.showRaw = CommandLine.arguments.contains("--coach-raw")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { Coach.shared.start(tutorial) }
        }
    }

    private var tutorial: CoachTutorial {
        let s = state
        return CoachTutorial(id: "demo", title: "Tour", symbol: "sparkles", summary: "A demo", steps: [
            CoachStep(id: "intro", title: "Let's look around", text: "This is a quick tour. I'll point at things and tell you what they do; tap the glowing button each time to move on."),
            CoachStep(id: "add", anchors: ["add-game"], title: "Add a game", text: "This brings a game in from a store you are signed in to, or from a Windows program in Files.",
                      points: [CoachPoint(symbol: "folder.fill", text: "Files: a game folder or a Windows installer"), CoachPoint(symbol: "arrow.down.circle.fill", text: "A store: Steam, Epic Games, GOG and more")]),
            CoachStep(id: "stores", anchors: ["tab-stores"], title: "Stores", text: "Open this to sign in to a store and install games you own.", advance: .until({ s.tab == "stores" }),
                      ensure: nil, shape: .capsule, prompt: "Tap Stores"),
            CoachStep(id: "steam", anchors: ["store-steam"], title: "Steam", text: "Tap Steam to sign in. Your password is encrypted before it leaves the device.", advance: .until({ s.sheet })),
            CoachStep(id: "signin", anchors: ["steam-signin"], title: "Sign in", text: "This opens Steam's own sign-in.", advance: .until({ !s.sheet })),
            CoachStep(id: "settings", anchors: ["tab-settings"], title: "Settings", text: "Everything about how the app runs is here.", advance: .until({ s.tab == "settings" }), shape: .capsule),
            CoachStep(id: "backup", anchors: ["sv-auto"], title: "Back up your saves", text: "Turn this on and your saves are copied each time a game ends.", advance: .until({ s.autoBackup }), prompt: "Switch it on"),
            CoachStep(id: "end", title: "That's it", text: "You can run any tutorial again from Settings."),
        ])
    }
}
