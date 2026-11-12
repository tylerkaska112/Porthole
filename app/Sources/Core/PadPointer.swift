// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// The controller's mouse stick. A game running directly (the usual case) gets relative movement, as before, and the arrow on screen follows the game's REAL cursor,
/// which the engine reports (`winios_direct_cursor_*`; see `PadPointerView`), so it is exact whatever the engine does with the movement. In a desktop session
/// (Steam and the games it starts), where the engine draws the cursor itself but only follows absolute moves, the stick moves an absolute pointer this class keeps.
final class PadPointer: @unchecked Sendable {
    static let shared = PadPointer()
    private let lock = NSLock()
    private var x = 0.0, y = 0.0, w = 1280.0, h = 720.0
    private var placed = false          // the desktop pointer has a starting place
    private var used = false            // the stick has moved the pointer in this game
    private var lastMove: CFAbsoluteTime = 0

    static var desktopSession: Bool { getenv("MADEIRA_DESKTOP").map { String(cString: $0) == "1" } ?? false }

    /// The game's screen size in desktop pixels (the pointer stays inside it).
    func setSize(width: Double, height: Double) {
        lock.lock(); defer { lock.unlock() }
        guard width > 0, height > 0 else { return }
        w = width; h = height
        x = min(x, w - 1); y = min(y, h - 1)
    }

    /// The game hides its cursor (mouse look): the engine reports it. Asked at most ten times a second.
    private var hiddenAt: CFAbsoluteTime = 0, hiddenValue = false
    private func gameHidesCursor(now: CFAbsoluteTime) -> Bool {
        if now - hiddenAt > 0.1 {
            hiddenAt = now
            var state = winios_direct_cursor_state()
            winios_direct_cursor_get(&state)
            hiddenValue = state.reports > 0 && state.shown == 0 && state.image_serial != 0
        }
        return hiddenValue
    }

    /// The controller moved the mouse by this much (counts): send it to the game.
    func move(dx: Int, dy: Int) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        used = true; lastMove = now
        // In a desktop session the stick keeps an absolute pointer of its own. A game that hides the cursor for mouse look puts it back in the middle of the screen every frame and
        // reads how far it moved, which an absolute pointer that does not know about that sends as an ever bigger offset (the view spun at full speed). Mouse look gets relative moves.
        guard Self.desktopSession, !gameHidesCursor(now: now) else { lock.unlock(); winios_pointer(Int32(dx), Int32(dy), 0x1, 0); return }
        if !placed { placed = true; x = w / 2; y = h / 2 }
        x = min(max(x + Double(dx), 0), w - 1); y = min(max(y + Double(dy), 0), h - 1)
        let (px, py) = (Int32(x), Int32(y))
        lock.unlock()
        winios_pointer(px, py, 0x1 | 0x8000, 0)                  // MOVE | ABSOLUTE, so the compositor's cursor follows
    }

    /// The touch trackpad (TrackpadEngine) moved the pointer: the arrow shows, as for the controller's stick, and idles away the same way.
    func trackpadMoved() {
        lock.lock(); used = true; lastMove = CFAbsoluteTimeGetCurrent(); lock.unlock()
    }

    /// A touch put the game's pointer here (desktop pixels): the desktop pointer carries on from there.
    func set(x nx: Int32, y ny: Int32) {
        lock.lock(); defer { lock.unlock() }
        x = Double(nx); y = Double(ny); placed = true
    }

    /// Whether the stick has moved the pointer, and how long ago.
    func usage() -> (used: Bool, idle: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (used, used ? CFAbsoluteTimeGetCurrent() - lastMove : .infinity)
    }

    /// A new game.
    func reset() { lock.lock(); placed = false; used = false; lock.unlock() }
}
