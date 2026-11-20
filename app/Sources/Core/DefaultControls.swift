// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// The controls every game starts with: the person's choice, made once (Settings > Controls). A game that has controls of its own (a layout picked on its page or in the
/// in-game menu, a bind set, the on-screen game controller) keeps them; every other game follows this.
///
/// Whether a game then works with those controls is found out by playing: nothing here checks that the game wants a controller.
struct DefaultControls: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// The layout most games can be played with (ShippedLayouts.universal): a W A S D stick with Shift, Space and Ctrl for the left thumb, the mouse buttons and the usual keys in the bottom right
        /// corner, the rest of the right side free to drag in, and a Look / Mouse switch. A layout like the others, so its controls can be moved, resized and added to.
        case universal
        /// The on-screen game controller: a console-style controller drawn over the game (VirtualPadView), in the style, layout and size chosen under it. The game sees an Xbox pad.
        case onScreenPad
        /// A gamepad on screen (TouchLayout.gamepad): both sticks, D-pad, A B X Y, bumpers, triggers. Its buttons can be moved, resized and added to.
        case gamepad
        /// A layout of the person's own, saved from the on-screen editor ("Use as my default").
        case custom
        var id: String { rawValue }
        /// "Mouse and keys" and "First person" (the two layouts the engine used to draw) are gone: Universal replaces them, so a choice saved by an older build reads as Universal.
        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .universal
        }
        var title: String {
            switch self { case .universal: "Universal"; case .onScreenPad: "On-screen controller"; case .gamepad: "Gamepad layout"; case .custom: "My own layout" }
        }
        var detail: String {
            switch self {
            case .universal: "W A S D, mouse buttons, keys and a Look switch."
            case .onScreenPad: "A console pad drawn on screen."
            case .gamepad: "Gamepad buttons you can move and resize."
            case .custom: "Save one from a game's menu."
            }
        }
    }

    var kind: Kind = .universal
    /// The layout `.custom` uses.
    var custom: TouchLayout?

    /// The layout drawn for `kind` when it is a layout (Universal, a gamepad, or the person's own); nil for the on-screen game controller, which has its own view.
    var touchLayout: TouchLayout? {
        switch kind {
        case .universal: return Self.universalLayout
        case .gamepad: return Self.gamepadLayout
        case .custom: return custom
        case .onScreenPad: return nil
        }
    }
    /// Made once, so every read gives the same controls (each control has its own id, and the screen redraws when the layout it is given is a different one).
    private static let gamepadLayout = TouchLayout.gamepad
    /// Universal, made once: the layout a game gets when nothing else supplies one.
    static let universalLayout = ShippedLayouts.universal.layout

    /// Whether games start with the on-screen game controller on.
    var usesOnScreenPad: Bool { kind == .onScreenPad }

    /// The person's own layout becomes the default.
    mutating func use(custom layout: TouchLayout) {
        custom = layout.sanitized()
        kind = .custom
    }

    /// A choice that has nothing behind it (a custom default with no layout, from a damaged file) is the original default.
    func normalised() -> DefaultControls {
        guard kind == .custom, custom == nil || custom?.controls.isEmpty == true else { return self }
        return DefaultControls()
    }

    /// Does a game follow the default? Not when it has controls of its own: a choice marked as its own, a bind set in use, or the on-screen
    /// game controller on.
    static func follows(own: Bool?, hasBindSet: Bool, virtualPad: Bool?) -> Bool {
        own != true && !hasBindSet && virtualPad != true
    }

    // MARK: Stored

    static let key = "f4.defaultControls"

    static func load(from defaults: UserDefaults = .standard) -> DefaultControls {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(DefaultControls.self, from: data) else { return DefaultControls() }
        return value.normalised()
    }

    static func save(_ value: DefaultControls, to defaults: UserDefaults = .standard) {
        if value == DefaultControls() { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    /// The saved default.
    static var current: DefaultControls {
        get { load() }
        set { save(newValue) }
    }
}
