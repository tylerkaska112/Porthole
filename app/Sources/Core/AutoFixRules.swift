// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Fetches the rules the Hub publishes for the automatic fixes (GET /autofix/rules.json), keeps the last good copy, and makes `AutoFix` use them. The list is only ever read, never
/// sent anything: it is the same server the compatibility badges come from. A list that cannot be read, is not of the schema this app knows or is too big is ignored and the last
/// good one (or the built-in rules) stays; a rule in it that asks for more than a rule may is left out (AutoFixRemote). A 404 means nothing is published any more and the app goes
/// back to its built-in rules, which is also how the Hub's `clear` works.
@MainActor
final class AutoFixRules {
    static let shared = AutoFixRules()
    private static let fetchedKey = "f4.autofix.rulesFetched"
    private static let refreshAfter: TimeInterval = 6 * 3600

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("f4-autofix-rules.json")
    }

    private static var build: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    private var refreshing = false

    /// Uses the last good copy now (no network), then looks for a newer one in the background.
    func start() {
        guard AutoFixStore.enabled else { return }
        if let data = try? Data(contentsOf: cacheURL), let result = AutoFixRemote.read(data, builtIn: AutoFix.builtIn, build: Self.build) {
            AutoFix.install(result.set)
            Self.log(result, from: "saved copy")
        }
        Task { await refreshIfStale() }
    }

    func refreshIfStale() async {
        guard AutoFixStore.enabled, !refreshing else { return }
        let last = UserDefaults.standard.object(forKey: Self.fetchedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.refreshAfter else { return }
        refreshing = true
        defer { refreshing = false }
        guard let base = CompatClient.standard().baseURL else { return }
        var request = URLRequest(url: base.appendingPathComponent("autofix").appendingPathComponent("rules.json"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Porthole", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request), let http = response as? HTTPURLResponse else { return }   // offline: try again later
        switch http.statusCode {
        case 200:
            guard let result = AutoFixRemote.read(data, builtIn: AutoFix.builtIn, build: Self.build) else {
                LogStore.shared.log("[autofix] the Hub's rules list was not used (not a list this app knows, or too big); keeping the one in use", level: .error)
                return
            }
            try? data.write(to: cacheURL, options: .atomic)
            UserDefaults.standard.set(Date(), forKey: Self.fetchedKey)
            AutoFix.install(result.set)
            Self.log(result, from: "the Hub")
        case 404:
            try? FileManager.default.removeItem(at: cacheURL)
            UserDefaults.standard.set(Date(), forKey: Self.fetchedKey)
            AutoFix.install(nil)
            LogStore.shared.log("[autofix] rules: the Hub publishes none; the \(AutoFix.builtIn.count) built-in rules are in use")
        default:
            break      // an error answer: keep what is in use, ask again next time
        }
    }

    private static func log(_ result: AutoFixRemote.Result, from source: String) {
        LogStore.shared.log("[autofix] rules from \(source): \(AutoFix.builtIn.count) built in, \(result.used.count) published (\(result.used.joined(separator: ", "))), switched off: \(result.disabled.isEmpty ? "none" : result.disabled.joined(separator: ", "))"
                            + (result.rejected.isEmpty ? "" : "; left out: \(result.rejected.joined(separator: "; "))"))
    }
}
