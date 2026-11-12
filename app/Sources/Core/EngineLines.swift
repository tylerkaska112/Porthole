// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Engine lines a known program cannot start without, added to the game's own engine text by the app instead of by the person. The lines are read once, when Porthole starts, so the
/// start that adds them is stopped and the person is told to open Porthole again (SessionController.engineLinesNeed).
enum EngineLines {
    struct Rule: Equatable {
        let name: String
        let lines: [String]
    }

    /// Blender (Steam copy, or the zip from blender.org): its OpenGL needs 4.3 and the 2:10:10:10 vertex format, which Zink on MoltenVK does not offer by itself.
    static let blender = Rule(name: "Blender", lines: [
        "env.MESA_GL_VERSION_OVERRIDE = 4.3",
        "env.MESA_GLSL_VERSION_OVERRIDE = 430",
        "env.MESA_EXTENSION_OVERRIDE = +GL_ARB_vertex_type_2_10_10_10_rev",
    ])

    /// The rule for a program, by the name of its file (a Windows path or a name) or by Steam's app id (365960 is Blender on Steam).
    static func rule(forExe exe: String, steamAppID: Int?) -> Rule? {
        let name = exe.lowercased().split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
        if name == "blender.exe" || name == "blender-launcher.exe" || steamAppID == 365960 { return blender }
        return nil
    }

    private static func key(_ line: String) -> String {
        (line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The lines whose setting the text does not mention yet. A setting the person already made, with whatever value, is theirs and is not asked for again.
    static func missing(_ lines: [String], in config: String?) -> [String] {
        let present = Set((config ?? "").components(separatedBy: .newlines).map(key).filter { !$0.isEmpty })
        return lines.filter { !present.contains(key($0)) }
    }

    /// The text with the lines added at the end; what was there stays as it is.
    static func adding(_ lines: [String], to config: String?) -> String {
        let text = (config ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ([text].filter { !$0.isEmpty } + lines).joined(separator: "\n")
    }
}
