// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import UIKit

/// A report this install sent to the Porthole server, with what the maintainer has answered. Reports are private: only this install (and the maintainer) can read them.
struct ProblemEntry: Decodable, Identifiable, Equatable {
    let id: Int
    let clientId: String
    let description: String
    let status: String               // open, reviewed, fixed
    let note: String
    let fixedIn: String
    let version: String
    let build: String
    let createdAt: Double            // milliseconds since 1970
    let updatedAt: Double
    var created: Date { Date(timeIntervalSince1970: createdAt / 1000) }
    var updated: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}

/// Sending a problem report to the Porthole server and reading the answers. Uses the same per-install key as the compatibility reports: no account.
enum ProblemClient {
    /// Whether this build knows a server to send to.
    static var available: Bool { CompatClient.standard().baseURL != nil }

    private struct Sent: Decodable { let id: Int; let status: String }

    /// `logPacked` is the whole log, deflated and in base64 (see `ProblemReport.packed`); empty when the log is left out.
    static func send(description: String, facts: String, logPacked: String) async throws {
        var body: [String: Any] = [
            "clientId": UUID().uuidString.lowercased(), "description": description, "facts": facts,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "engine": CompatEngine.id, "device": CompatDeviceInfo.current?.id ?? "", "ios": UIDevice.current.systemVersion,
        ]
        if !logPacked.isEmpty { body["logGz"] = logPacked }
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await CompatClient.standard().signed("POST", "/problems/reports", body: data, long: true, as: Sent.self)
    }

    static func mine() async throws -> [ProblemEntry] {
        try await CompatClient.standard().signed("GET", "/problems/mine", as: [ProblemEntry].self)
    }

    static func withdraw(id: Int) async throws {
        struct Done: Decodable { let deleted: Bool }
        _ = try await CompatClient.standard().signed("DELETE", "/problems/reports/\(id)", as: Done.self)
    }
}

/// What the person has sent and what came back. The settings list shows a badge while an answer has not been looked at.
@MainActor
final class ProblemTracker: ObservableObject {
    static let shared = ProblemTracker()
    @Published private(set) var entries: [ProblemEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// Reports whose status changed since the person last looked.
    @Published private(set) var unseen = 0

    private static let seenKey = "f4.problemsSeen"       // [id: updatedAt ms]
    private var seen: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.seenKey) }
    }

    func refresh() async {
        guard ProblemClient.available, NetworkStatus.shared.isOnline else { return }      // offline: what is saved stays, quietly
        loading = true; error = nil
        defer { loading = false }
        do {
            entries = try await ProblemClient.mine()
            recount()
        } catch let failure as CompatError {
            if case .server(let status, _) = failure, status == 401 || status == 404 { entries = []; recount(); return }     // no reports yet, or the server has no such service yet
            error = ErrorText.plain(failure)
        } catch { self.error = ErrorText.plain(error) }
    }

    /// The person has looked at the list: every answer so far counts as seen.
    func markSeen() {
        var current = seen
        for e in entries { current[String(e.id)] = e.updatedAt }
        seen = current
        recount()
    }

    func withdraw(_ entry: ProblemEntry) async {
        do { try await ProblemClient.withdraw(id: entry.id); entries.removeAll { $0.id == entry.id }; recount() }
        catch { self.error = ErrorText.plain(error) }
    }

    /// The reports that were answered since the person last looked (the Home notice and the Settings badge).
    var answered: [ProblemEntry] {
        let known = seen
        return entries.filter { $0.status != "open" && $0.updatedAt > (known[String($0.id)] ?? 0) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func recount() { unseen = answered.count }
}
