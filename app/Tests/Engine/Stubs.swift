import Foundation

// Stand-ins for the app's own types, with only what the code under test uses.
struct LogEntry { enum Level { case info, error, success } }
final class LogStore { static let shared = LogStore(); var lines: [String] = []; func log(_ message: String, level: LogEntry.Level = .info) { lines.append(message) } }

struct Game: Codable, Equatable {
    var exe: String
    var args: String = ""
    var engine: GameEngine?
    var bindSets: [BindSet]?
    var activeBindSetID: UUID?
    var settings: GameSettings?
    var launchDirect: Bool?
    var dockAppID: Int?
    var steamAppID: Int?
    var settingsUndo: RecommendedSettings.Undo?
}
struct GameSettings: Codable, Equatable {
    var powerMode: Int?; var keepModeWhenHot: Bool?; var swapMB: Int?; var swapCoverage: String?; var vramMB: Int?; var audioCushionMs: Int?
    var preciseMath: Bool?; var dockDesktop: Bool?; var lookSensitivity: Double?; var resolution: String?
    var isEmpty: Bool { self == GameSettings() }
}
enum AppModel {
    nonisolated static func unixURL(forWindows path: String) -> URL? {
        guard path.count > 3, path.lowercased().hasPrefix("c:\\") else { return nil }
        let parts = path.dropFirst(3).split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        return parts.reduce(driveC) { $0.appendingPathComponent($1) }
    }
    nonisolated static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    nonisolated static var driveC: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("wine/drive_c") }
}
func wineserver_is_ready() -> Int32 { 1 }
func wineserver_is_running() -> Int32 { 1 }

// Stand-in for UIKit's UIScreen (EngineOptions reads the screen's size and refresh rate; there is no UIKit on the Mac).
#if !canImport(UIKit)
import CoreGraphics
final class UIScreen {
    nonisolated(unsafe) static let main = UIScreen()
    var nativeBounds = CGRect(x: 0, y: 0, width: 1290, height: 2796)
    var maximumFramesPerSecond = 120
}
#endif

// Stand-ins for app types that need UIKit, CoreMotion, CryptoKit or the Launcher package. EngineOptions only starts and ends their sessions; none of the checks run them.
struct PadAssistSettings: Codable, Equatable {}
enum InstallCheck {
    enum Donor { case ready, notReady }
    static var donorMemory: Donor { .ready }
    static var donorMemoryNote: String { "" }
}
@MainActor final class LosslessScaling {
    static let shared = LosslessScaling()
    static let windowsControlPath = "", windowsShaderPath = ""
    var usable: Bool { false }
    func startGame(enabled: Bool, generated: Int) -> Bool { false }
    func sessionEnded() {}
    func prepareForGame() -> Bool { false }
}
@MainActor final class LiveUpscaling {
    static let shared = LiveUpscaling()
    nonisolated static var isAllowed: Bool { false }
    nonisolated static let windowsControlPath = ""
    func startGame(saved: Double?, method: Int, sharpness: Int) {}
    func sessionEnded() {}
}
