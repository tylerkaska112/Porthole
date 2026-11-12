// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import UIKit

/// The settings a launch actually uses: the game's own override where it has one, else the global setting.
@MainActor
struct LaunchSettings {
    var power: PowerMode
    var keepModeWhenHot: Bool
    var swapMB: Int
    var swapCoverage: String
    var vramMB: Int
    var audioCushionMs: Int
    var preciseMath: Bool
    var dockDesktop: Bool
    var lookSensitivity: Double
    var resolution: String            // DisplayResolution id

    static let defaultLookSensitivity = 2.4, lookRange = 0.4...8.0
    static var globalLookSensitivity: Double {
        get { (UserDefaults.standard.object(forKey: "f4.lookSensitivity") as? Double) ?? defaultLookSensitivity }
        set { UserDefaults.standard.set(newValue, forKey: "f4.lookSensitivity") }
    }

    // MARK: Resolution

    static let resolutionKey = "f4.resolution"
    static var globalResolution: String {
        get { DisplayResolution.offered(UserDefaults.standard.string(forKey: resolutionKey)) ?? DisplayResolution.defaultID }
        set { UserDefaults.standard.set(newValue, forKey: resolutionKey) }
    }
    /// Width / height of this device's screen in landscape, for the "screen shape" sizes.
    static var screenAspect: Double {
        let b = UIScreen.main.bounds
        let w = max(b.width, b.height), h = min(b.width, b.height)
        return h > 0 ? Double(w / h) : 16.0 / 9.0
    }
    /// The size of the virtual screen this launch uses.
    var displaySize: DisplayResolution { DisplayResolution.resolve(id: resolution, screenAspect: Self.screenAspect) }

    // MARK: Global values (UserDefaults; swap and video memory used to live only in madeira.cfg, which is now written at launch from these)

    enum Key {
        static let swapMB = "f4.swapMB", swapCoverage = "f4.swapCoverage", vramMB = "f4.vramMB"
    }

    /// A device whose app limit is about 4 GB: the 6 GB iPhones and iPads (A15 and A16 class report 5.6 to 5.9 GB; an 8 GB one reports 7.3 GB or more). A 64-bit game with a big working set runs
    /// past that limit within a minute and iOS ends the app (Supermarket Simulator, CORDURA Playtest and Legends of Idleon, 2026-11-05, all with Swap off), so Swap starts on there.
    /// Only a default: a value the person ever set, "Off" included, wins, and so does a game's own override.
    static var lowMemoryDevice: Bool { ProcessInfo.processInfo.physicalMemory < UInt64(6656) << 20 }
    static let lowMemorySwapMB = 4096, lowMemorySwapCoverage = "wide"

    static var globalSwapMB: Int {
        get { (UserDefaults.standard.object(forKey: Key.swapMB) as? Int) ?? Int(MadeiraConfig.get("swap-mb") ?? "") ?? (lowMemoryDevice ? lowMemorySwapMB : 0) }
        set { UserDefaults.standard.set(newValue, forKey: Key.swapMB) }
    }
    static var globalSwapCoverage: String {
        get {
            if let v = UserDefaults.standard.string(forKey: Key.swapCoverage) { return v }
            let v = (MadeiraConfig.get("env.MADEIRA_SWAP_COVERAGE") ?? "").lowercased()
            if v.isEmpty, MadeiraConfig.get("swap-mode") == "2" { return "broad" }   // the old Engine options row; see EngineOptions.migrateSwapMode()
            if v.isEmpty, lowMemoryDevice { return lowMemorySwapCoverage }   // nobody chose one: the default for a 4 GB app limit (1 MB and up), see lowMemoryDevice
            return v == "classic" ? "" : v
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.swapCoverage) }
    }
    static var globalVramMB: Int {
        get { (UserDefaults.standard.object(forKey: Key.vramMB) as? Int) ?? Int(MadeiraConfig.get("vram-mb") ?? "") ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: Key.vramMB) }
    }

    static func resolve(for game: Game?) -> LaunchSettings {
        let o = game?.settings ?? GameSettings()
        return LaunchSettings(
            power: o.powerMode.flatMap(PowerMode.init(rawValue:)) ?? PowerManager.shared.userMode,
            keepModeWhenHot: o.keepModeWhenHot ?? PowerManager.shared.ignoreHeat,
            swapMB: o.swapMB ?? globalSwapMB,
            swapCoverage: o.swapCoverage ?? GameFixes.fix(forSteamAppID: game?.dockAppID ?? game?.steamAppID)?.swapCoverage ?? globalSwapCoverage,
            vramMB: o.vramMB ?? globalVramMB,
            audioCushionMs: o.audioCushionMs ?? SessionController.audioCushionMs,
            preciseMath: o.preciseMath ?? SessionController.preciseMath,
            dockDesktop: o.dockDesktop ?? SessionController.dockDesktop,
            lookSensitivity: o.lookSensitivity ?? globalLookSensitivity,
            resolution: DisplayResolution.offered(o.resolution) ?? globalResolution)
    }

    /// Writes what the runtime reads from madeira.cfg and tells PowerManager what this session uses. Call right before a launch.
    func apply() {
        EngineOptions.migrateSwapMode()
        _ = MadeiraConfig.set("swap-mb", swapMB > 0 ? String(swapMB) : nil)
        _ = MadeiraConfig.set("env.MADEIRA_SWAP_COVERAGE", swapMB > 0 && !swapCoverage.isEmpty ? swapCoverage : nil)
        _ = MadeiraConfig.set("vram-mb", vramMB > 0 ? String(vramMB) : nil)
        PowerManager.shared.beginSession(mode: power, keepWhenHot: keepModeWhenHot)
        LogStore.shared.log("[settings] launch: power=\(power.title) keepHot=\(keepModeWhenHot) swap=\(swapMB)MB/\(swapCoverage.isEmpty ? "classic" : swapCoverage) vram=\(vramMB) audio=\(audioCushionMs)ms precise=\(preciseMath) desktop=\(dockDesktop) resolution=\(displaySize.text)")
    }
}
