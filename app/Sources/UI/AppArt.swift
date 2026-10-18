// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI

/// Connects the kit's picture requests to Steam's artwork: finds the game on Steam once (and remembers it), then fetches the tile header or the wide hero.
enum AppArt {
    static let loader: ArtLoader = { id, kind in
        guard let game = await MainActor.run(body: { AppModel.shared.games.first { $0.id == id } }) else { return nil }
        // An Epic game has its own pictures (the wide one for the tile and backdrop, the box art as a fallback).
        if game.epicAppName != nil, let url = (kind == .hero ? game.epicHeroURL ?? game.epicArtworkURL : game.epicHeroURL ?? game.epicArtworkURL),
           let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) { return image }
        if game.gogID != nil, let url = game.gogArtURL,
           let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) { return image }
        if game.itchID != nil, let url = game.itchArtURL,
           let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) { return image }
        if game.amazonID != nil, let url = game.amazonArtURL,
           let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) { return image }
        var steamID = game.steamAppID
        if steamID == nil {
            let found = await SteamArt.shared.appID(name: game.name, exe: game.exe) ?? 0
            steamID = found
            await MainActor.run { AppModel.shared.setSteamAppID(found, for: game) }
        }
        guard let sid = steamID, sid > 0 else { return nil }
        return kind == .hero ? await SteamArt.shared.image(appID: sid) : await SteamArt.shared.header(appID: sid)
    }
}
