// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// What HardwareInput (a keyboard, mouse or trackpad in a game) reads from the engine options, once a second so a change in Settings applies in a running game.
/// All of them are `env.` lines of madeira.cfg, so a game's own settings (GameFixes) can set them too.
final class InputSettings: @unchecked Sendable {
    static let shared = InputSettings()
    private let lock = NSLock()
    private var read: CFAbsoluteTime = 0
    private var cached = (sens: 1.0, relative: false, diagnostics: false, ignore: true, scroll: 1.0, menu: Optional(KeyBind.defaultMenu), lock: Optional(KeyBind.defaultLock))

    /// "Mouse speed": a multiplier on the mouse's own movement while the game reads it relatively (mouse look). 1 = the device's movement unchanged.
    static let sensKey = "env.PORTHOLE_MOUSE_SPEED"
    /// "Mouse look": the mouse always moves the camera (relative movement and the pointer locked) instead of following the game's cursor.
    static let relativeKey = "env.PORTHOLE_MOUSE_LOOK"
    /// More `[hwinput]` lines in the log (route changes, raw movement, button samples).
    static let diagnosticsKey = "env.PORTHOLE_INPUT_DIAGNOSTICS"

    /// The keys that open Porthole's menu and lock the pointer in a game ("none" = no key of its own; Ctrl+Alt+M and Ctrl+Alt+P always work).
    static let menuKeyKey = "env.PORTHOLE_KEY_MENU", lockKeyKey = "env.PORTHOLE_KEY_LOCK"
    /// "reversed" turns the wheel around for games and for the shelf of games on Home.
    static let scrollKey = "env.PORTHOLE_SCROLL_DIRECTION"

    private func refresh() -> (sens: Double, relative: Bool, diagnostics: Bool, ignore: Bool, scroll: Double, menu: KeyBind?, lock: KeyBind?) {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if now - read < 1 { return cached }
        read = now
        // A game's own choice (Game page > Engine) is in its own lines; the app-wide setting is the fallback.
        func value(_ key: String) -> String? { MadeiraConfig.gameValue(key) ?? MadeiraConfig.get(key) }
        let sens = value(Self.sensKey).flatMap(Double.init) ?? 1
        cached = (min(max(sens, 0.1), 8), value(Self.relativeKey) == "1", MadeiraConfig.get(Self.diagnosticsKey) == "1",
                  MadeiraConfig.get("env.PORTHOLE_MOUSE_IGNORE_TOUCHES") != "0", MadeiraConfig.get(Self.scrollKey) == "reversed" ? -1 : 1,
                  Self.bind(MadeiraConfig.get(Self.menuKeyKey), fallback: .defaultMenu), Self.bind(MadeiraConfig.get(Self.lockKeyKey), fallback: .defaultLock))
        return cached
    }

    private static func bind(_ text: String?, fallback: KeyBind) -> KeyBind? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return fallback }
        return text.lowercased() == "none" ? nil : (KeyBind.parse(text) ?? fallback)
    }
    /// "" = the editing keys repeat, "all", "off".
    var keyRepeat: String { MadeiraConfig.gameValue("env.PORTHOLE_KEY_REPEAT") ?? MadeiraConfig.get("env.PORTHOLE_KEY_REPEAT") ?? "" }
    var keyLayoutLetters: Bool { (MadeiraConfig.gameValue("env.PORTHOLE_KEY_LAYOUT") ?? MadeiraConfig.get("env.PORTHOLE_KEY_LAYOUT")) == "letters" }
    var menuBind: KeyBind? { refresh().menu }
    var lockBind: KeyBind? { refresh().lock }
    var scrollSign: Double { refresh().scroll }
    var sensMouse: Double { refresh().sens }
    var relative: Bool { refresh().relative }
    var diagnostics: Bool { refresh().diagnostics }
    /// iPhone (AssistiveTouch): a touch that is really a mouse click is not a finger.
    var ignoreTouchesWithMouse: Bool { refresh().ignore }
}
