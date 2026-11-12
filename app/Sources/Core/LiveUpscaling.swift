// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import UIKit

/// MetalFX upscaling that the in-game menu changes while the game runs (engine patch 0199). The app writes a small control file in the game's prefix
/// (`C:\ProgramData\Porthole\upscale.ctl`: `mode=0|1|2`, `factor=`, `fit=`); the Direct3D 11 swap chain and the Direct3D 12 Present look at it twice a second, rebuild the scaler and the
/// layer's size when it changed, and write what they did to `upscale.ctl.status` for the menu. The choice made at the game's start (Game ▸ Engine ▸ Upscaling) is written first, so the
/// file and the old launch variables always agree. `MADEIRA_UPSCALE_LIVE = 0` (an `env.` line in the global or the game's config) leaves the file out: upscaling is then fixed at the start.
@MainActor
final class LiveUpscaling: ObservableObject {
    static let shared = LiveUpscaling()

    nonisolated static let windowsControlPath = #"C:\ProgramData\Porthole\upscale.ctl"#
    private var folder: URL { AppModel.prefix.appendingPathComponent("drive_c/ProgramData/Porthole", isDirectory: true) }
    private var controlFileURL: URL { folder.appendingPathComponent("upscale.ctl") }
    private var statusFileURL: URL { folder.appendingPathComponent("upscale.ctl.status") }

    enum Mode: Int { case off = 0, screen = 1, fixed = 2 }

    /// What enlarges the picture: Apple's MetalFX, or Lossless Scaling's own upscalers (they need the owner's copy, see LosslessScaling).
    enum Method: Int { case metalfx = 0, ls1 = 1, ls1p = 2 }

    struct Live: Equatable {
        var mode: Mode = .off
        var factor = 2.0          // for .fixed (1 to 2)
        var method: Method = .metalfx
        var sharpness = 3         // 1 to 5, the Lossless Scaling upscalers

        /// The saved per-game setting (`GameEngine.upscaleFactor`: nil = off, 0 = to the screen, else a factor) as a live setting.
        init(saved: Double?, method: Int = 0, sharpness: Int = 3) {
            self.method = Method(rawValue: method) ?? .metalfx
            self.sharpness = min(max(sharpness, 1), 5)
            guard let f = saved, f == 0 || f > 1 else { self.mode = .off; return }
            if f == 0 { self.mode = .screen } else { self.mode = .fixed; self.factor = min(f, 2.0) }
        }
        init(mode: Mode = .off, factor: Double = 2.0, method: Method = .metalfx, sharpness: Int = 3) { self.mode = mode; self.factor = factor; self.method = method; self.sharpness = min(max(sharpness, 1), 5) }

        /// Back to what `GameEngine.upscaleFactor` stores.
        var saved: Double? {
            switch mode { case .off: return nil; case .screen: return 0; case .fixed: return factor }
        }
    }

    @Published private(set) var live = Live()
    /// Whether the control file is in use for the running game (it is not when `MADEIRA_UPSCALE_LIVE = 0`).
    @Published private(set) var controlled = false

    nonisolated static var isAllowed: Bool {
        let v = MadeiraConfig.gameValue("env.MADEIRA_UPSCALE_LIVE") ?? MadeiraConfig.get("env.MADEIRA_UPSCALE_LIVE")
        return v != "0"
    }

    /// A game is about to start with this saved setting: a fresh control file with it (and no old status).
    func startGame(saved: Double?, method: Int = 0, sharpness: Int = 3) {
        try? FileManager.default.removeItem(at: statusFileURL)
        controlled = true
        write(Live(saved: saved, method: method, sharpness: sharpness))
    }

    /// The menu changed the choice of the running game.
    func apply(_ new: Live) {
        guard controlled else { return }
        var v = new
        // Lossless Scaling's upscalers need the shaders file in the prefix: written when the choice is made in the game.
        if v.method != .metalfx, v.mode != .off, !(LosslessScaling.shared.usable && LosslessScaling.shared.prepareForGame()) { v.method = .metalfx }
        write(v)
    }

    private func write(_ v: Live) {
        live = v
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let px = EngineLaunch.screenPixels()
        let text = "mode=\(v.mode.rawValue)\nfactor=\(v.factor)\nfit=\(px.width)x\(px.height)\nmethod=\(v.method.rawValue)\nlevel=\(v.sharpness - 1)\n"
        try? text.write(to: controlFileURL, atomically: true, encoding: .utf8)
    }

    /// What the engine said last, as lines "key=value" (state, factor, from, to, message). Empty when it has said nothing.
    func engineStatus() -> [String: String] {
        guard let text = try? String(contentsOf: statusFileURL, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    /// The status as a sentence for the menu.
    func statusText() -> String {
        let st = engineStatus()
        switch st["state"] {
        case "on":
            let f = Double(st["factor"] ?? "") ?? 0
            let who: String
            switch st["method"] {
            case "ls1": who = "Lossless Scaling LS1 (sharpness \(st["level"] ?? "?"))"
            case "ls1p": who = "Lossless Scaling LS1 performance (sharpness \(st["level"] ?? "?"))"
            default: who = "MetalFX"
            }
            let fallback = st["fallback"].map { " Lossless Scaling was chosen but \($0)." } ?? ""
            return "On: the game draws \(st["from"] ?? "?") and \(who) enlarges it \(String(format: "%.2f", f))\u{00D7} to \(st["to"] ?? "?").\(fallback)"
        case "same-size":
            return "Nothing to enlarge: the game already draws about as large as the screen (\(st["from"] ?? "?")). Lower this game\u{2019}s Resolution (Game \u{25B8} Display) to give it something to enlarge."
        case "unsupported":
            return "This device has no MetalFX spatial scaler."
        case "error":
            return "Not working: \(st["message"] ?? "unknown reason")."
        case "off":
            return live.mode == .off ? "Off." : "Waiting for the game\u{2019}s next frame."
        default:
            return live.mode == .off ? "Off. Direct3D 11 and 12 games; the game does not restart." : "Waiting for the game to draw. If nothing is reported after a few seconds this game may use something else (Direct3D 9 or 10, OpenGL, Vulkan)."
        }
    }

    /// The game is over: the control files do not stay in the prefix.
    func sessionEnded() {
        try? FileManager.default.removeItem(at: controlFileURL)
        try? FileManager.default.removeItem(at: statusFileURL)
        controlled = false
        live = Live()
    }
}
