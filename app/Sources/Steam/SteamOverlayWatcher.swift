// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
// Steam's overlay inside a running game cannot draw here (its window process fails to make its browser), but the part inside the game still works: when the game
// asks for the overlay (its Workshop or Store button, or the Shift+Tab shortcut) it writes "Showing overlay ..." to Steam's `logs/gameoverlay_renderer.txt` and takes the
// game's input. This watches that file so the app can show its own Steam menu instead and give the game its input back.
import Foundation

enum SteamOverlayLog {
    /// How many times the overlay was asked for in this piece of the log.
    static func showRequests(in text: String) -> Int {
        text.split(separator: "\n").filter { $0.contains("Showing overlay") }.count
    }
}

@MainActor
final class SteamOverlayWatcher {
    static let shared = SteamOverlayWatcher()
    private var task: Task<Void, Never>?

    func stop() { task?.cancel(); task = nil }

    /// `onRequest` runs on the main actor each time the overlay is asked for (at most once every two seconds).
    func start(steamFolder: URL, isRunning: @escaping @MainActor () -> Bool, onRequest: @escaping @MainActor () -> Void) {
        stop()
        let file = steamFolder.appendingPathComponent("logs/gameoverlay_renderer.txt")
        task = Task { @MainActor in
            var offset: UInt64 = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map { UInt64($0) } ?? 0
            var identity: Data?
            var lastRequest = Date.distantPast
            SteamLog.event("[overlay] watching \(file.lastPathComponent) from byte \(offset)")
            while !Task.isCancelled, isRunning() {
                if let handle = try? FileHandle(forReadingFrom: file) {
                    defer { try? handle.close() }
                    let size = (try? handle.seekToEnd()) ?? 0
                    // Steam starts the file afresh for each game: the first bytes tell a new file from the old one.
                    try? handle.seek(toOffset: 0)
                    let head = (try? handle.read(upToCount: 160)) ?? Data()
                    if let known = identity, known != head { offset = 0 }       // a new game's file: all of it is new
                    if identity == nil, size < offset { offset = 0 }
                    identity = head
                    if size < offset { offset = 0 }
                    if size > offset, (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: Int(min(size - offset, 65536))) {
                        offset += UInt64(data.count)
                        if SteamOverlayLog.showRequests(in: String(decoding: data, as: UTF8.self)) > 0, Date().timeIntervalSince(lastRequest) > 2 {
                            lastRequest = Date()
                            SteamLog.event("[overlay] the game asked for Steam's overlay")
                            onRequest()
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}
