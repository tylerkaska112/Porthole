// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import NetworkExtension
import LauncherCore

/// Why a tunnel didn't come up, written to the log in plain words: what iOS itself reported, and how the tunnel extension was signed
/// (a profile that lacks the VPN permission, belongs to another team, or has expired stops the extension from ever starting).
enum TunnelDiagnostics {
    /// Facts about the signing of the app and its tunnel extension, one per line.
    static func signingReport() -> [String] {
        let app = profile(in: Bundle.main)
        guard let plugins = Bundle.main.builtInPlugInsURL, let appex = Bundle(url: plugins.appendingPathComponent("F4Tunnel.appex")) else {
            return ["the tunnel extension (F4Tunnel.appex) is not inside this app"]
        }
        let ext = profile(in: appex)
        var lines = ["app: \(Bundle.main.bundleIdentifier ?? "?")  profile \(describe(app))",
                     "tunnel extension: \(appex.bundleIdentifier ?? "?")  profile \(describe(ext))"]
        if let app, let ext {
            if app.profile.teamID != ext.profile.teamID { lines.append("PROBLEM: the app and its tunnel extension are signed by different teams (\(app.profile.teamID) vs \(ext.profile.teamID))") }
            if !ext.packetTunnel { lines.append("PROBLEM: the tunnel extension's profile does not include the packet tunnel (VPN) permission") }
            if let end = ext.profile.expiration, end < Date() { lines.append("PROBLEM: the tunnel extension's profile expired on \(end.formatted(date: .abbreviated, time: .omitted))") }
        } else if ext == nil {
            lines.append("PROBLEM: the tunnel extension carries no provisioning profile, so iOS will not run it")
        }
        return lines
    }

    /// What iOS recorded the last time the tunnel stopped or failed to start.
    static func lastDisconnectReason(_ connection: NEVPNConnection) async -> String? {
        await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                guard let error = error as NSError? else { continuation.resume(returning: nil); return }
                continuation.resume(returning: "\(error.domain) \(error.code): \(ErrorText.plain(error))")
            }
        }
    }

    static func name(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: "invalid"; case .disconnected: "disconnected"; case .connecting: "connecting"; case .connected: "connected"
        case .reasserting: "reasserting"; case .disconnecting: "disconnecting"; @unknown default: "unknown"
        }
    }

    private struct Found { var profile: ProvisioningProfile; var packetTunnel: Bool }

    private static func profile(in bundle: Bundle) -> Found? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url), let parsed = try? ProvisioningProfile(data: data) else { return nil }
        return Found(profile: parsed, packetTunnel: hasPacketTunnel(data))
    }

    /// The profile is a signed wrapper around a property list; the permission is a key in its Entitlements.
    private static func hasPacketTunnel(_ data: Data) -> Bool {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return false }
        let key = entitlements["com.apple.developer.networking.networkextension"] as? [String] ?? []
        return key.contains { $0.hasPrefix("packet-tunnel-provider") }
    }

    private static func describe(_ found: Found?) -> String {
        guard let found else { return "none" }
        let p = found.profile
        let expiry = p.expiration.map { "expires " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "no expiry"
        return "\u{201C}\(p.name)\u{201D} team \(p.teamID), \(expiry), VPN permission \(found.packetTunnel ? "yes" : "NO")"
    }
}
