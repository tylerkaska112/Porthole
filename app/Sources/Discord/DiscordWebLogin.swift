// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import WebKit

/// Sign in on Discord's own login page, inside Porthole. Discord's page asks for the password, the captcha and the two-step code; Porthole never sees them.
/// Once the page has signed in, Porthole reads the account's sign-in token from the page, keeps it in the Keychain, and throws the page's cookies away.
struct DiscordWebLogin: View {
    let onToken: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = "Sign in as you would on discord.com."

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(message).font(.footnote).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                DiscordLoginWebView(onToken: { token in onToken(token); dismiss() }, onMessage: { message = $0 })
            }
            .navigationTitle("Sign in to Discord")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct DiscordLoginWebView: UIViewRepresentable {
    let onToken: (String) -> Void
    let onMessage: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken, onMessage: onMessage) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()          // nothing of this sign-in stays in the app
        let view = WKWebView(frame: .zero, configuration: config)
        view.load(URLRequest(url: URL(string: "https://discord.com/login")!))
        context.coordinator.start(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator {
        let onToken: (String) -> Void
        let onMessage: (String) -> Void
        private var timer: Timer?
        private var done = false
        init(onToken: @escaping (String) -> Void, onMessage: @escaping (String) -> Void) { self.onToken = onToken; self.onMessage = onMessage }

        /// Discord's page hides its token from `localStorage`; a fresh frame of the same page still has it.
        private static let script = """
        (function(){ try { var f = document.createElement('iframe'); document.body.appendChild(f);
          var t = f.contentWindow.localStorage.getItem('token'); f.remove(); return t || ''; } catch (e) { return ''; } })()
        """

        func start(_ view: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self, weak view] _ in
                Task { @MainActor in
                    guard let self, let view, !self.done, let host = view.url?.host, host.hasSuffix("discord.com"), view.url?.path.hasPrefix("/login") == false else { return }
                    view.evaluateJavaScript(Self.script) { [weak self] result, _ in
                        Task { @MainActor in
                            guard let self, !self.done, let raw = result as? String, !raw.isEmpty else { return }
                            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                            guard token.count > 20 else { return }
                            self.done = true
                            self.timer?.invalidate()
                            self.onMessage("Signed in.")
                            self.onToken(token)
                        }
                    }
                }
            }
        }

        func stop() { timer?.invalidate(); timer = nil }
    }
}
