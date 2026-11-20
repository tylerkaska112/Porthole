// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreVideo
import Foundation

/// The game's own picture for Go Live: what the game's window layer presents (Runtime/Winios/GameCapture.m), at the game's shape, scaled to fit the stream's size. No touch controls,
/// no in-game menu, no overlay, and not the phone's screen shape. DXMT and Vulkan games both present into the window layer that is tapped.
final class DiscordGameCapture: @unchecked Sendable {
    let width: Int, height: Int, fps: Int

    init(width: Int, height: Int, fps: Int) { self.width = width; self.height = height; self.fps = fps }

    /// The size to stream at: the game's picture size, scaled down to fit 1280x720 if bigger (never enlarged), both sides even. Nil when no game window is drawing yet.
    static func outputSize(box: (width: Int, height: Int) = (1280, 720)) -> (width: Int, height: Int)? {
        let size = porthole_game_picture_size()
        guard size.width >= 16, size.height >= 16 else { return nil }
        let scale = min(Double(box.width) / Double(size.width), Double(box.height) / Double(size.height), 1)
        return ((Int(Double(size.width) * scale) / 2) * 2, (Int(Double(size.height) * scale) / 2) * 2)
    }

    func start(onFrame: @escaping (CVPixelBuffer, Int) -> Void, onFailure: @escaping (String) -> Void) {
        let status = porthole_game_capture_start(Int32(width), Int32(height), Int32(fps)) { pixels, number in onFrame(pixels, Int(number)) }
        if status != 0 { onFailure("No game window is drawing a picture yet. Start the game first, then Go Live.") }
    }

    func stop() { porthole_game_capture_stop() }
}
