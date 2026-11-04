// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// The account's own games, found the way Steam's client finds them: the licence list Steam sends at log-on names the packages the account owns,
// the packages name their apps, and each app's product information says what it is and whether it has a Windows version.
import Foundation

extension SteamCMBackend {
    /// The installable Windows games this account owns, with their product information (name, install folder, build, launch options, depots).
    func ownedApps(completion: @escaping (Result<[SteamAppInfo], SteamContentError>) -> Void) {
        ownedLibrary { completion($0.map(\.apps)) }
    }

    /// The same, with every depot the account's packages list (what decides which DLC depots an install can really fetch, so the size shown matches the install).
    func ownedLibrary(completion: @escaping (Result<(apps: [SteamAppInfo], depots: Set<Int>), SteamContentError>) -> Void) {
        start { [weak self] started in
            guard let self else { return }
            if case .failure(let error) = started { completion(.failure(error)); return }
            self.waitForLicenses { licenses in
                guard let licenses else { completion(.failure(SteamContentError(message: "Steam did not send the list of your games. Try again."))); return }
                SteamLog.event("[steam-library] licences=\(licenses.count)")
                self.installableLibrary(for: licenses, completion: completion)
            }
        }
    }

    /// The installable Windows games the given licences lead to (packages -> apps -> product information). The connection must be logged on.
    func installableApps(for licenses: [SteamLicense], completion: @escaping (Result<[SteamAppInfo], SteamContentError>) -> Void) {
        installableLibrary(for: licenses) { completion($0.map(\.apps)) }
    }

    func installableLibrary(for licenses: [SteamLicense], completion: @escaping (Result<(apps: [SteamAppInfo], depots: Set<Int>), SteamContentError>) -> Void) {
        packageInfo(licenses) { packages in
            let appIDs = Array(Set(packages.flatMap(\.appIDs))).sorted()
            let depotIDs = Set(packages.flatMap(\.depotIDs))
            SteamLog.event("[steam-library] packages=\(packages.count) apps=\(appIDs.count) depots=\(depotIDs.count)")
            self.appInfos(appIDs) { infos in
                let games = infos.filter { SteamDepotPlanner.isInstallableGame($0) }
                SteamLog.event("[steam-library] app-info=\(infos.count) installable=\(games.count)")
                completion(.success((games, depotIDs)))
            }
        }
    }

    /// Every depot of every package the account owns (a depot is only downloadable if one of these lists it).
    func ownedDepotIDs(completion: @escaping (Set<Int>) -> Void) {
        waitForLicenses { [weak self] licenses in
            guard let self, let licenses else { completion([]); return }
            self.packageInfo(licenses) { completion(Set($0.flatMap(\.depotIDs))) }
        }
    }

    // MARK: Pieces

    private func waitForLicenses(_ completion: @escaping ([SteamLicense]?) -> Void) {
        var finished = false
        func done() {
            guard !finished else { return }
            finished = true
            // A long list can come in more than one message: give the rest a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { completion(nil); return }
                self.cm.onLicenses = nil
                completion(self.cm.licenses.filter(\.isActive))
            }
        }
        if cm.licenseListComplete { done(); return }
        cm.onLicenses = { done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard !finished else { return }
            finished = true
            self?.cm.onLicenses = nil
            completion(nil)
        }
    }

    /// Product information for packages, 200 at a time. Unknown or unreadable packages are left out.
    private func packageInfo(_ licenses: [SteamLicense], completion: @escaping ([SteamPackageInfo]) -> Void) {
        var unique: [Int: UInt64] = [:]
        for license in licenses { unique[license.packageID] = license.accessToken }
        let ids = unique.keys.sorted()
        var found: [SteamPackageInfo] = []
        func batch(_ start: Int) {
            guard start < ids.count else { completion(found); return }
            let slice = ids[start..<min(start + 200, ids.count)]
            var request = PBWriter()
            for id in slice {
                var entry = PBWriter(); entry.varint(1, UInt64(id)); if let token = unique[id], token != 0 { entry.varint(2, token) }
                request.message(1, entry)
            }
            request.bool(3, false)
            productInfo(request) { replies in
                for reply in replies {
                    for entry in reply.messages(3) {
                        guard let id = entry.uint(1), let buffer = entry.data(5), let info = SteamPackageInfo.parse(buffer, packageID: Int(id)) else { continue }
                        found.append(info)
                    }
                }
                batch(start + 200)
            }
        }
        batch(0)
    }

    /// Product information for apps, 100 at a time (with the access tokens Steam wants for them).
    private func appInfos(_ appIDs: [Int], completion: @escaping ([SteamAppInfo]) -> Void) {
        accessTokens(for: appIDs) { [weak self] tokens in
            guard let self else { completion([]); return }
            var found: [SteamAppInfo] = []
            func batch(_ start: Int) {
                guard start < appIDs.count else { completion(found); return }
                var request = PBWriter()
                for id in appIDs[start..<min(start + 100, appIDs.count)] {
                    var entry = PBWriter(); entry.varint(1, UInt64(id)); if let token = tokens[id], token != 0 { entry.varint(2, token) }
                    request.message(2, entry)
                }
                request.bool(3, false)
                self.productInfo(request) { replies in
                    for reply in replies {
                        for entry in reply.messages(1) {
                            guard let id = entry.uint(1), let buffer = entry.data(5), !buffer.isEmpty,
                                  let info = SteamAppInfoParser.parse(buffer, appid: Int(id)) else { continue }
                            found.append(info)
                        }
                    }
                    batch(start + 100)
                }
            }
            batch(0)
        }
    }

    private func accessTokens(for appIDs: [Int], completion: @escaping ([Int: UInt64]) -> Void) {
        var tokens: [Int: UInt64] = [:]
        func batch(_ start: Int) {
            guard start < appIDs.count else { completion(tokens); return }
            var request = PBWriter()
            for id in appIDs[start..<min(start + 1000, appIDs.count)] { request.varint(2, UInt64(id)) }
            cm.wait(for: EMsg.picsAccessTokenResponse, timeout: 30, match: { _ in true }) { reply in
                if case .success(let packet) = reply, let fields = PBFields(packet.body) {
                    for entry in fields.messages(3) { if let id = entry.uint(1) { tokens[Int(id)] = entry.uint(2) ?? 0 } }
                }
                batch(start + 1000)
            }
            cm.send(EMsg.picsAccessTokenRequest, body: request.data)
        }
        batch(0)
    }

    /// Sends one product-information request and collects the reply messages (Steam splits a big answer and marks all but the last "pending").
    private func productInfo(_ request: PBWriter, completion: @escaping ([PBFields]) -> Void) {
        var replies: [PBFields] = []
        func next() {
            cm.wait(for: EMsg.picsProductInfoResponse, timeout: 45, match: { _ in true }) { reply in
                guard case .success(let packet) = reply, let fields = PBFields(packet.body) else { completion(replies); return }
                replies.append(fields)
                if fields.bool(6) == true { next() } else { completion(replies) }
            }
        }
        next()
        cm.send(EMsg.picsProductInfoRequest, body: request.data)
    }
}
