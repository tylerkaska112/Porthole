// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Amazon's own login page in a sheet; when signed in it shows the account and closes, like Epic's.
struct AmazonSignInView: View {
    @ObservedObject private var auth = AmazonAuth.shared
    @ObservedObject private var library = AmazonLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPaste = false
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            Group {
                if let name = auth.accountName { account(name) } else { login }
            }
            .navigationTitle("Amazon Games").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(auth.signedIn ? "Done" : "Cancel") { dismiss() } }
                if !auth.signedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Menu { Button("Paste the address Amazon sent you to") { showPaste = true } } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .alert("Sign-in address", isPresented: $showPaste) {
                TextField("the address you were sent to", text: $pasted).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Sign in") { if let code = AmazonAuth.extractCode(from: pasted) { auth.finishLogin(code: code) } else { auth.signInError = "That address has no sign-in code in it." }; pasted = "" }
                Button("Cancel", role: .cancel) { pasted = "" }
            }
            .onAppear { auth.refresh() }
            .onChange(of: auth.accountName) { old, name in
                guard name != nil else { library.clear(); return }
                library.refresh()
                if old == nil { dismiss() }
            }
        }
    }

    private var login: some View {
        ZStack {
            AmazonLoginWebView { code in auth.finishLogin(code: code) }.ignoresSafeArea(edges: .bottom)
            if auth.isBusy {
                Color(uiColor: .systemBackground).opacity(0.85).ignoresSafeArea()
                ProgressView("Signing in\u{2026}")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = auth.signInError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
                    .padding(12).frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
    }

    private func account(_ name: String) -> some View {
        Form {
            Section {
                LabeledContent("Signed in as", value: name)
                LabeledContent("Games", value: library.isLoading ? "Loading\u{2026}" : "\(library.games.count)")
                Button("Sign out of Amazon Games", role: .destructive) { auth.signOut(); library.clear() }
            }
            if let error = library.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
    }
}
