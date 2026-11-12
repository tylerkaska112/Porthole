// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

// Bind sets: several named sets of controls per game, one in use at a time. A set can carry controller binds (what each controller button does in
// keyboard-and-mouse mode), an on-screen touch layout, or both. A set is a separate layer: using one never writes the game's own controller or touch
// settings, and with none in use everything behaves as before. A set is plain data, so it can be exported to a file and, later, shared.

/// One on-screen control of a custom touch layout.
struct TouchControlSpec: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    /// A `PadActions` id for a button ("key-E", "space", "lmb", "wheelup"), or "stick-wasd" / "stick-arrows" for a stick.
    var action: String
    /// For a key: "latch" (each tap switches it on or off) or anything else, which is a plain press: down while touched, never shorter than a tap ("tap" and "hold" are the same thing). Mouse buttons always hold; the wheel always taps.
    var mode: String = "tap"
    /// The centre as a fraction of the screen (0 to 1 each way), so a layout fits any screen shape.
    var x: Double
    var y: Double
    /// The control's width in points.
    var size: Double = 54
    /// A combo: modifier keys ("shift", "ctrl", "alt") held down together with a key control's own key while it is pressed (Shift+Space, Ctrl+C).
    var with: [String] = []
    static let comboModifiers = ["shift", "ctrl", "alt"]
    /// How a key or mouse button is drawn: nil is the usual round button; "rounded" a rounded square, "square" nearly square.
    var shape: String?
    /// A colour for a key or mouse button (nil is the usual dark one); a name from `colours`.
    var colour: String?
    static let shapes = ["round", "rounded", "square"]
    static let colours = ["red", "orange", "yellow", "green", "blue", "purple", "white"]

    static let modes = ["tap", "hold", "latch"]
    var isStick: Bool { action == "stick-wasd" || action == "stick-arrows" }
    /// The on-screen pad's button, trigger, stick or D-pad this control is (mixed layouts, TouchPadControls.swift), or nil for a key, a mouse button or the W A S D stick.
    var pad: TouchPadControl? { TouchPadControl(action: action) }
    /// Drawn big and round with no label of its own: the key sticks, and the pad's sticks and D-pad.
    var isRound: Bool { isStick || pad?.isRound == true }
    /// What a small picture of the control shows (the layouts list and the shared layouts).
    var faceText: String {
        if isStick { return action == "stick-arrows" ? "\u{2191}\u{2190}\u{2192}\u{2193}" : "WASD" }
        switch action { case "stick-ls": return "LS"; case "stick-rs": return "RS"; case "dpad-pad": return "+"; default: return label }
    }

    init(id: UUID = UUID(), label: String, action: String, mode: String = "tap", x: Double, y: Double, size: Double = 54, with: [String] = [], shape: String? = nil, colour: String? = nil) {
        self.id = id; self.label = label; self.action = action; self.mode = mode; self.x = x; self.y = y; self.size = size; self.with = with; self.shape = shape; self.colour = colour
    }

    /// Tolerant: the server's copy of a layout has no ids, and a file may leave out the mode or the size.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        action = try c.decode(String.self, forKey: .action)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "tap"
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 54
        with = try c.decodeIfPresent([String].self, forKey: .with) ?? []
        shape = try c.decodeIfPresent(String.self, forKey: .shape)
        colour = try c.decodeIfPresent(String.self, forKey: .colour)
    }
    /// Options at their defaults are left out, so a layout that does not use them reads (and is sent to the Hub) exactly as before.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(label, forKey: .label); try c.encode(action, forKey: .action); try c.encode(mode, forKey: .mode)
        try c.encode(x, forKey: .x); try c.encode(y, forKey: .y); try c.encode(size, forKey: .size)
        if !with.isEmpty { try c.encode(with, forKey: .with) }
        if let shape { try c.encode(shape, forKey: .shape) }
        if let colour { try c.encode(colour, forKey: .colour) }
    }
    enum CodingKeys: String, CodingKey { case id, label, action, mode, x, y, size, with, shape, colour }
}

/// A set of on-screen controls plus whether dragging on the game looks around (like the first-person layout).
struct TouchLayout: Codable, Equatable {
    var controls: [TouchControlSpec] = []
    var look = false
    /// How solid the controls are drawn while playing (1 = as before; the editor always shows them fully).
    var opacity = 1.0
    /// A light tap on the phone when a control is pressed.
    var haptics = true
    /// The editor does not move, resize or delete controls while this is on (the settings of a control can still be changed).
    var locked = false
    static let opacityRange = 0.25...1.0

    init(controls: [TouchControlSpec] = [], look: Bool = false, opacity: Double = 1, haptics: Bool = true, locked: Bool = false) { self.controls = controls; self.look = look; self.opacity = opacity; self.haptics = haptics; self.locked = locked }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controls = try c.decodeIfPresent([TouchControlSpec].self, forKey: .controls) ?? []
        look = try c.decodeIfPresent(Bool.self, forKey: .look) ?? false
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(controls, forKey: .controls); try c.encode(look, forKey: .look)
        if opacity != 1 { try c.encode(opacity, forKey: .opacity) }
        if !haptics { try c.encode(haptics, forKey: .haptics) }
        if locked { try c.encode(locked, forKey: .locked) }
    }
    enum CodingKeys: String, CodingKey { case controls, look, opacity, haptics, locked }

    static let maxControls = 40
    static let sizeRange = 32.0...160.0

    /// What a shared file may contain: known actions only, positions and sizes in range, short labels, at most `maxControls`.
    func sanitized() -> TouchLayout {
        var out: [TouchControlSpec] = []
        for var c in controls.prefix(Self.maxControls) {
            guard c.isStick || c.pad != nil || (PadActions.list + PadActions.touchOnly).contains(where: { $0.id == c.action && $0.id != "none" }) else { continue }
            c.label = String(c.label.filter { !$0.isNewline && $0 != "\u{0}" }.prefix(8))
            c.mode = TouchControlSpec.modes.contains(c.mode) ? c.mode : "tap"
            c.x = c.x.isFinite ? min(max(c.x, 0.02), 0.98) : 0.5
            c.y = c.y.isFinite ? min(max(c.y, 0.04), 0.96) : 0.5
            c.size = c.size.isFinite ? min(max(c.size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) : 54
            var seen = Set<String>()
            c.with = c.with.filter { TouchControlSpec.comboModifiers.contains($0) && $0 != c.action && seen.insert($0).inserted }
            if c.isStick || c.pad != nil { c.with = [] }
            if case .key = PadActions.action(c.action) {} else { c.with = [] }      // a combo is for a key control
            if let s = c.shape, !TouchControlSpec.shapes.contains(s) || c.isStick || c.pad != nil { c.shape = nil }
            if let k = c.colour, !TouchControlSpec.colours.contains(k) || c.isStick || c.pad != nil { c.colour = nil }
            out.append(c)
        }
        let o = opacity.isFinite ? min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound) : 1
        return TouchLayout(controls: out, look: look, opacity: o, haptics: haptics, locked: locked)
    }

    /// Starting points for the editor, close to the built-in layouts.
    static var mouseAndKeys: TouchLayout {
        TouchLayout(controls: [
            TouchControlSpec(label: "", action: "stick-wasd", x: 0.12, y: 0.74, size: 104),
            TouchControlSpec(label: "E", action: "key-E", x: 0.93, y: 0.78, size: 46),
            TouchControlSpec(label: "F", action: "key-F", x: 0.85, y: 0.78, size: 46),
            TouchControlSpec(label: "Tab", action: "tab", x: 0.93, y: 0.62, size: 46),
            TouchControlSpec(label: "Esc", action: "esc", x: 0.85, y: 0.62, size: 46),
            TouchControlSpec(label: "Space", action: "space", mode: "hold", x: 0.77, y: 0.78, size: 56),
            TouchControlSpec(label: "Shift", action: "shift", mode: "latch", x: 0.77, y: 0.62, size: 50),
        ], look: false)
    }
    /// A gamepad: both sticks, the D-pad, A B X Y, bumpers, triggers, Menu and View, placed like an Xbox controller. Every control can be moved, resized or removed, and keys and mouse
    /// buttons added to it (a mixed layout).
    static var gamepad: TouchLayout {
        func pad(_ id: String, _ x: Double, _ y: Double, _ size: Double, mode: String = "tap") -> TouchControlSpec {
            TouchControlSpec(label: TouchPadControl.entry(id)?.face ?? "", action: id, mode: mode, x: x, y: y, size: size)
        }
        return TouchLayout(controls: [
            pad("stick-ls", 0.11, 0.56, 120), pad("dpad-pad", 0.29, 0.80, 98), pad("stick-rs", 0.69, 0.80, 110),
            pad("pad-y", 0.87, 0.33, 50), pad("pad-a", 0.87, 0.67, 50), pad("pad-x", 0.795, 0.50, 50), pad("pad-b", 0.945, 0.50, 50),
            pad("pad-lb", 0.10, 0.10, 46), pad("pad-lt", 0.20, 0.10, 46), pad("pad-rb", 0.90, 0.10, 46), pad("pad-rt", 0.80, 0.10, 46),
            pad("pad-back", 0.43, 0.10, 40), pad("pad-start", 0.57, 0.10, 40),
        ], look: false)
    }
    static var firstPerson: TouchLayout {
        TouchLayout(controls: [
            TouchControlSpec(label: "", action: "stick-wasd", x: 0.13, y: 0.72, size: 120),
            TouchControlSpec(label: "FIRE", action: "lmb", x: 0.90, y: 0.80, size: 76),
            TouchControlSpec(label: "ALT", action: "rmb", x: 0.79, y: 0.80, size: 76),
            TouchControlSpec(label: "Jump", action: "space", mode: "hold", x: 0.90, y: 0.58, size: 60),
            TouchControlSpec(label: "Use", action: "key-E", x: 0.79, y: 0.58, size: 54),
            TouchControlSpec(label: "Duck", action: "ctrl", mode: "hold", x: 0.27, y: 0.84, size: 54),
            TouchControlSpec(label: "Run", action: "shift", mode: "hold", x: 0.27, y: 0.66, size: 54),
            TouchControlSpec(label: "R", action: "key-R", x: 0.70, y: 0.88, size: 46),
        ], look: true)
    }
}

/// What the controller part of a set carries: what each controller input does, and the right stick's up-and-down speed. Using a set with this part
/// switches the game to keyboard-and-mouse mode for the controller.
struct PadPart: Codable, Equatable {
    var binds: [String: String] = [:]      // only what differs from the standard layout
    var mouseVertical: Double?

    init(binds: [String: String] = [:], mouseVertical: Double? = nil) { self.binds = binds; self.mouseVertical = mouseVertical }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        binds = try c.decodeIfPresent([String: String].self, forKey: .binds) ?? [:]
        mouseVertical = try c.decodeIfPresent(Double.self, forKey: .mouseVertical)
    }
    enum CodingKeys: String, CodingKey { case binds, mouseVertical }

    func sanitized() -> PadPart {
        var out: [String: String] = [:]
        for (k, v) in binds {
            if PadActions.buttons.contains(k), PadActions.list.contains(where: { $0.id == v }) { out[k] = v }
            else if k == "LS" || k == "RS", PadActions.stickModes.contains(where: { $0.id == v }) { out[k] = v }
        }
        let vertical = mouseVertical.flatMap { $0.isFinite ? min(max($0, 0.25), 2.0) : nil }
        return PadPart(binds: out, mouseVertical: vertical == 1 ? nil : vertical)
    }
}

struct BindSet: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var notes = ""
    var created = Date()
    var updated = Date()
    var pad: PadPart?
    var touch: TouchLayout?
    /// The id of this install's published copy on the Hub (set once it has been shared), so sharing again updates it instead of adding another.
    var remoteID: Int?
    /// The id of the shared set this one was downloaded from.
    var downloadedFrom: Int?

    var summary: String {
        [pad != nil ? "Controller" : nil, touch != nil ? "Touch layout" : nil].compactMap { $0 }.joined(separator: " and ").nonEmpty ?? "Empty"
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

// MARK: - Files

/// The file a bind set is exported to and imported from (`.portholebinds`, plain JSON). Everything read from a file is checked: unknown actions and
/// out-of-range numbers are dropped, text is cut short, and a file over 64 KB is refused.
enum BindSetFile {
    static let format = "porthole-binds", version = 1, maxBytes = 64 * 1024, fileExtension = "portholebinds"

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var game: String?
        var name: String
        var notes: String?
        var pad: PadPart?
        var touch: TouchLayout?
    }

    static func encode(_ set: BindSet, gameName: String) throws -> Data {
        let e = Envelope(format: format, version: version, game: gameName, name: set.name, notes: set.notes.isEmpty ? nil : set.notes, pad: set.pad, touch: set.touch)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(e)
    }

    enum Failure: LocalizedError {
        case tooLarge, notBinds, newer, empty
        var errorDescription: String? {
            switch self {
            case .tooLarge: "That file is too big to be a bind set."
            case .notBinds: "That is not a Porthole bind set."
            case .newer: "That bind set was made by a newer version of Porthole."
            case .empty: "That bind set has nothing in it."
            }
        }
    }

    static func decode(_ data: Data) throws -> (set: BindSet, game: String?) {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard let e = try? JSONDecoder().decode(Envelope.self, from: data), e.format == format else { throw Failure.notBinds }
        guard e.version <= version else { throw Failure.newer }
        let pad = e.pad?.sanitized(), touch = e.touch?.sanitized()
        guard pad != nil || touch != nil else { throw Failure.empty }
        let name = clean(e.name, 40)
        return (BindSet(name: name.isEmpty ? "Imported set" : name, notes: clean(e.notes ?? "", 300), pad: pad, touch: touch), e.game.map { clean($0, 80) })
    }

    /// Text from a file: line breaks and tabs become spaces, other control characters are removed, runs of spaces collapse, cut to `max`.
    static func clean(_ text: String, _ max: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if CharacterSet.newlines.contains(u) || u == "\t" { scalars.append(" ") }
            else if !CharacterSet.controlCharacters.contains(u) { scalars.append(u) }
        }
        let words = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(words.prefix(max)).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Per game

extension Game {
    /// The set in use, if any.
    var activeBindSet: BindSet? { bindSets?.first { $0.id == activeBindSetID } }
}
