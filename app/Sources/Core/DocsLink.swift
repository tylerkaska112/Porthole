// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import SwiftUI
import UIKit

/// Links from a message in the app to what the website's documentation says about it (portholehq.site/docs).
///
/// Two kinds of link:
///  * a message the documentation has an entry for goes straight to that entry (`known`), and
///  * any other message is looked up: the text goes after the `#` of the address, which the browser keeps to itself (it is never sent to the website's server), and the
///    documentation's search reads it there. File and folder names in the text are left out first, so they do not end up in the browser's history either.
/// Nothing is opened until the person taps the button.
enum DocsLink {
    static let base = "https://portholehq.site/docs/"

    /// Messages with an entry of their own in the documentation: (a piece of the message, the entry's id on /docs/errors.html).
    static let known: [(match: String, entry: String)] = [
        ("pairing file needed", "pairing-file-needed"),
        ("large address space is not allowed", "large-address-space-not-allowed"),
        ("did not accept the saved sign-in", "steam-sign-in-refused"),
        ("minimum required feature level", "dx11-feature-level-12-0"),
        ("cannot find this game's program", "game-program-not-found"),
        ("drive mapping is already in use", "drive-mapping-in-use"),
    ]

    static func url(forMessage message: String) -> URL? {
        let lower = message.lowercased()
        for item in known where lower.contains(item.match) {
            return URL(string: base + "errors.html#" + item.entry)
        }
        let words = message.split(whereSeparator: { $0.isWhitespace }).filter { !$0.contains("/") && !$0.contains("\\") }.prefix(40).joined(separator: " ")
        guard !words.isEmpty else { return URL(string: base) }
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "&=+#")
        guard let encoded = words.addingPercentEncoding(withAllowedCharacters: allowed) else { return URL(string: base) }
        return URL(string: base + "#q=" + encoded)
    }

    /// Whether the website describes a setting of this name (the list is written when the documentation is built, so a newer setting has no button until then).
    static func documented(_ title: String) -> Bool { documentedSettings.contains(title) }

    /// The documentation's list of settings, already filtered to the one named (its title).
    static func url(forSetting title: String) -> URL? {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "&=+#")
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: allowed) else { return URL(string: base + "settings.html") }
        return URL(string: base + "settings.html#q=" + encoded)
    }

    /// An engine line's entry: the page names each one by its key with everything but letters and digits made a hyphen.
    static func url(forEngineLine key: String) -> URL? {
        let slug = key.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        let trimmed = slug.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return URL(string: base + "engine-lines.html#" + String(trimmed.prefix(80)))
    }

    static func open(_ message: String) {
        if let url = url(forMessage: message) { UIApplication.shared.open(url) }
    }
}

/// "What does this mean?" under an error: opens the documentation's entry for it in the browser.
struct ErrorHelpButton: View {
    let message: String
    var body: some View {
        Button { DocsLink.open(message) } label: {
            Label("What does this mean?", systemImage: "questionmark.circle").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the Porthole website in your browser")
    }
}
