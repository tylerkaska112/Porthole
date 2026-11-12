// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import WebKit

/// EA's own login page in a sheet. When the login finishes, EA sends the page to the EA app's private address (qrc:///html/login_successful.html) with a one-use code;
/// Porthole stops that navigation, reads the code and signs in. That address can also be pasted, for logins the web view cannot complete. (After Madeira's EASignInView.)
struct EASignInView: View {
    @ObservedObject private var auth = EAAuth.shared
    @ObservedObject private var library = EALibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var failure: String?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            Group {
                if auth.signedIn { account } else {
                    EALoginWebView(reload: reload) { code in submit(code) }
                        .ignoresSafeArea(edges: .bottom)
                        .overlay {
                            if busy {
                                ProgressView("Signing in\u{2026}").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                }
            }
            .navigationTitle("EA app").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(auth.signedIn ? "Done" : "Cancel") { dismiss() } }
                if !auth.signedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Paste the sign-in address", systemImage: "doc.on.clipboard") { pasted = ""; pasting = true }
                            Button("Reload", systemImage: "arrow.clockwise") { reload += 1 }
                        } label: { Label("More", systemImage: "ellipsis.circle") }
                    }
                }
            }
            .alert("Sign in with an address", isPresented: $pasting) {
                TextField("qrc:///html/login_successful.html?code=\u{2026}", text: $pasted).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Sign in") { submit(pasted) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If the page shows an address that ends in login_successful.html with a code, copy that whole address and paste it here.")
            }
            .alert("EA app", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil; reload += 1 }
            } message: { Text(failure ?? "") }
        }
    }

    private var account: some View {
        Form {
            Section {
                LabeledContent("Signed in as", value: auth.accountName ?? "EA account")
                LabeledContent("Games", value: library.isLoading ? "Loading\u{2026}" : "\(library.games.count)")
                Button("Sign out of the EA app", role: .destructive) { auth.signOut() }
            } footer: {
                Text("Games you installed stay, but an EA game needs this sign-in to start: its licence comes from your account.")
            }
            if let error = library.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        guard let code = EAAPI.authorizationCode(in: text) else {
            failure = "This is not an EA sign-in address. Copy the address of the page EA opens after you sign in."
            return
        }
        busy = true
        Task {
            do {
                try await auth.signIn(code: code)
                busy = false
                dismiss()
            } catch {
                busy = false
                failure = ErrorText.plain(error)
            }
        }
    }
}

/// WKWebView with EA's login page, in a private (non-persistent) data store. The navigation to the EA app's private end-of-login address is stopped and handed on.
struct EALoginWebView: UIViewRepresentable {
    var reload: Int
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: EAAuth.shared.loginURL()))
        context.coordinator.loadedReload = reload
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onCode = onCode
        if context.coordinator.loadedReload != reload {
            context.coordinator.loadedReload = reload
            context.coordinator.delivered = false
            view.load(URLRequest(url: EAAuth.shared.loginURL()))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onCode: (String) -> Void
        var loadedReload = 0
        var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, EAAPI.isRedirectPage(url) {
                decisionHandler(.cancel)
                deliver(url)
                return
            }
            decisionHandler(.allow)
        }

        /// The private scheme could not load (the web view has no handler for it): its address has the code.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if let url = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL, EAAPI.isRedirectPage(url) { deliver(url) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url, EAAPI.isRedirectPage(url) { deliver(url) }
        }

        private func deliver(_ url: URL) {
            guard !delivered, EAAPI.authorizationCode(in: url.absoluteString) != nil else { return }
            delivered = true
            onCode(url.absoluteString)
        }

        /// Links that open a new window load in this one.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
