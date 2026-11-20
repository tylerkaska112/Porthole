// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// Follows Legendary's get_launch_parameters (derrod and contributors, GPL-3.0-or-later): what Epic's own launcher puts on a game's command line.

import Foundation

/// The command line Epic's launcher gives a game besides the sign-in code: the sandbox the game belongs to (Epic Online Services reads it), the ownership token a game with
/// online ownership checks asks for, and the extra arguments Epic's catalog lists for the game. Pure text work, so it is tested without a network.
enum EpicLaunchArguments {
    /// What Epic's catalog says a launch needs, read from the game's `customAttributes`.
    struct Attributes: Equatable {
        /// The game checks an ownership token (Legendary: `requires_ot`, "OwnershipToken" = "true"). Epic's launcher fetches one and passes `-epicovt=<file>`.
        var requiresOwnershipToken = false
        /// Extra arguments Epic's launcher adds ("AdditionalCommandLine").
        var additionalCommandLine = ""
    }

    /// Reads the attributes of one catalog item from Epic's bulk-items answer (`{ "<catalogItemId>": { "customAttributes": { "OwnershipToken": { "value": "true" } } } }`).
    /// Written to take anything: an answer of another shape gives the plain defaults, never an error, because a launch must not fail over this.
    static func attributes(fromCatalog json: Any, catalogItemId: String) -> Attributes {
        guard let all = json as? [String: Any], let item = all[catalogItemId] as? [String: Any], let custom = item["customAttributes"] as? [String: Any] else { return Attributes() }
        func value(_ key: String) -> String? {
            custom.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }.flatMap { ($0.value as? [String: Any])?["value"] as? String }
        }
        var out = Attributes()
        out.requiresOwnershipToken = value("OwnershipToken")?.lowercased() == "true"
        out.additionalCommandLine = cleaned(value("AdditionalCommandLine") ?? "")
        return out
    }

    /// Extra arguments from the catalog, made safe to put on a command line: no control characters (a line break would start another command in some launchers), no longer than
    /// a command line needs to be, and nothing that would replace the sign-in.
    static func cleaned(_ text: String) -> String {
        let plain = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let words = plain.split(separator: " ", omittingEmptySubsequences: true).filter { !$0.lowercased().hasPrefix("-auth_") && !$0.lowercased().hasPrefix("-epicuserid") && !$0.lowercased().hasPrefix("-epicusername") }
        let joined = words.joined(separator: " ")
        return joined.count > 400 ? "" : joined
    }

    /// The arguments Epic's launcher passes for a game, in Legendary's order. Each is later wrapped in double quotes by the caller, so none may hold a quote or a control character.
    static func build(appName: String, exchangeCode: String, displayName: String, accountID: String, namespace: String?, ownershipTokenPath: String?) throws -> [String] {
        var arguments = ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=" + exchangeCode, "-AUTH_TYPE=exchangecode", "-epicapp=" + appName, "-epicenv=Prod"]
        if let path = ownershipTokenPath, !path.isEmpty { arguments.append("-epicovt=" + path) }
        arguments += ["-EpicPortal", "-epicusername=" + displayName, "-epicuserid=" + accountID, "-epiclocale=en"]
        if let namespace, !namespace.isEmpty { arguments.append("-epicsandboxid=" + namespace) }
        guard arguments.allSatisfy({ !$0.contains("\"") && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw Invalid() }
        return arguments
    }

    struct Invalid: Error {}

    /// The Windows path of a game's ownership-token file inside Porthole's drive C (one file per game; the folder is emptied before a new one is written).
    static let tokenFolder = "C:\\ProgramData\\Porthole\\epic-ovt"
    static func tokenPath(appName: String) -> String {
        let safe = String(appName.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return tokenFolder + "\\" + (safe.isEmpty ? "game" : safe) + ".ovt"
    }
}
