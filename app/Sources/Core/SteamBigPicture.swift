// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// Adapted from Madeira's Library.swift (ml2021 Big Picture, GPL-3.0-or-later, Copyright 2026 125hz): the batch file and the folder it starts the client from.
import Foundation

/// Valve's own Steam client in Big Picture (its gamepad interface) inside the Wine desktop, as a one-off program.
///
/// Madeira marks this unfinished and leaves it out of its release builds. It is a heavy 64-bit Chromium host: it takes the memory lines Madeira tested for it (a 4 GB swap file and a
/// 4 GB donor pool among them), its first start downloads Valve's client from Valve's CDN into a folder of its own, and the interface can be slow. So it is offered as an experiment
/// (Settings > Stores > Steam), never started by itself.
///
/// Madeira Dock's Steam folder is pinned to the client build the Dock host supports, so the interface must never run from it: steam.exe there would complete its install from Valve's CDN
/// and replace the pinned build. Big Picture gets a folder of its own, seeded with the Dock's steam.exe, where Valve's bootstrapper completes the client.
@MainActor enum SteamBigPicture {
    /// Hidden: the row in Settings > Stores > Steam appears only after seven taps on the version (About) and the switch there (Big Picture's web helper has crashed on the first click).
    static let shownKey = "f4.bigPictureShown"
    static let id = UUID(uuidString: "5A0B2C44-9C1E-4D0F-8F2A-7B3E6D1C9A10")!

    /// Big Picture's own Steam folder (Windows path, Unix path).
    static var folder: (windows: String, unix: String) {
        ("C:\\Program Files\\Steam Big Picture", AppModel.driveC.appendingPathComponent("Program Files/Steam Big Picture").path)
    }

    /// Madeira Dock's Steam folder, when its steam.exe is there.
    private static var dockFolder: (windows: String, unix: String)? {
        let fm = FileManager.default
        let candidates = [("C:\\Program Files (x86)\\Steam", AppModel.driveC.appendingPathComponent("Program Files (x86)/Steam").path),
                          ("C:\\Program Files\\Steam", AppModel.driveC.appendingPathComponent("Program Files/Steam").path)]
        return candidates.first { fm.fileExists(atPath: "\($0.1)/steam.exe") }
    }

    /// Big Picture's folder has a client, or the Dock's steam.exe can seed one.
    static var available: Bool {
        FileManager.default.fileExists(atPath: "\(folder.unix)/steam.exe") || dockFolder != nil
    }

    /// Whether the client has completed itself here already (its first start downloads it).
    static var clientDownloaded: Bool {
        FileManager.default.fileExists(atPath: "\(folder.unix)/bin/cef/cef.win7/steamwebhelper.exe")
    }

    /// Writes C:\big-picture.bat for this start (seeding Big Picture's folder with the Dock's steam.exe the first time) and returns the program to run, or nil with the reason.
    static func prepare() -> (game: Game, error: String?) {
        var game = Game(name: "Steam Big Picture", exe: "C:\\big-picture.bat")
        game.id = id
        game.inDesktop = true
        game.installer = true            // a one-off program: never stored in the library, no badge, no report prompt
        let fm = FileManager.default
        let target = folder
        if !fm.fileExists(atPath: "\(target.unix)/steam.exe") {
            guard let dock = dockFolder else {
                LogStore.shared.log("[big-picture] no Steam client to start from: download the Steam client first", level: .error)
                return (game, "Big Picture starts from the Steam client. Download it first (Settings \u{203A} Stores \u{203A} Steam \u{203A} Steam client).")
            }
            do {
                try fm.createDirectory(atPath: target.unix, withIntermediateDirectories: true)
                try fm.copyItem(atPath: "\(dock.unix)/steam.exe", toPath: "\(target.unix)/steam.exe")
                LogStore.shared.log("[big-picture] seeded \(target.windows) with the Dock's steam.exe; Valve's client completes itself there on this first run (a download from Valve's CDN)")
            } catch {
                LogStore.shared.log("[big-picture] could not seed \(target.windows): \(error.localizedDescription)", level: .error)
                return (game, "Could not prepare Big Picture's folder: \(ErrorText.plain(error))")
            }
        }
        // ml2210: once the 32-bit client and its web helper are in place, the bootstrapper neither updates itself nor the client, so a later run cannot move it to the 64-bit client,
        // whose CEF pools do not fit the address space. env.MADEIRA_BIG_PICTURE_PIN = 0 lets it update as before.
        let pinned = MadeiraConfig.flag("MADEIRA_BIG_PICTURE_PIN", fallback: true) && clientDownloaded
        if pinned { LogStore.shared.log("[big-picture] ml2210 the installed 32-bit client is kept: no bootstrap update this run") }
        // ml2230: env.MADEIRA_BIG_PICTURE_GPU = 1 lets the web helper draw with the GPU (Chromium's ANGLE on the 32-bit D3D11); off by default, software drawing as before.
        let gpu = MadeiraConfig.flag("MADEIRA_BIG_PICTURE_GPU", fallback: false)
        if gpu { LogStore.shared.log("[big-picture] ml2230 the web helper may use the GPU (env.MADEIRA_BIG_PICTURE_GPU = 1)") }
        let bat = [
            "@echo off",
            "rem Generated by Porthole (after Madeira's ml2021) for Big Picture; rewritten at every start.",
            "start \"\" \"C:\\windows\\system32\\services.exe\"",
            "cd /d \"\(target.windows)\"",
            "\"\(target.windows)\\steam.exe\" -bigpicture -no-cef-sandbox" + (gpu ? "" : " -cef-disable-gpu") + " -console -nocrashmonitor"
                + (pinned ? " -nobootstrapperupdate -skipinitialbootstrap" : "")
                + " -cef-disable-features=SegmentationPlatform,OptimizationTargetPrediction,OptimizationHints",
        ].joined(separator: "\r\n") + "\r\n"
        do {
            try bat.write(to: AppModel.driveC.appendingPathComponent("big-picture.bat"), atomically: true, encoding: .utf8)
        } catch {
            LogStore.shared.log("[big-picture] could not write big-picture.bat: \(error.localizedDescription)", level: .error)
            return (game, "Could not write Big Picture's start file: \(ErrorText.plain(error))")
        }
        // Madeira's tested lines for this client: the memory layout a 64-bit Chromium host needs, the swap tier with the donor pool, the lock mode.
        GameTestedSetup.apply(GameRecommendations.steamBigPicture, to: &game)
        LogStore.shared.log("[big-picture] steam.exe -bigpicture from \(target.windows) in the Wine desktop")
        return (game, nil)
    }
}
