// Stand-ins for app types the UI kit's focus code reaches, so the preview app builds without the rest of the app.
import SwiftUI

enum LogEntryLevelStub { case info, error, success }
final class LogStore { nonisolated(unsafe) static let shared = LogStore(); func log(_ message: String, level: LogEntryLevelStub = .info) {} }

/// The same cases as Core/GameStores.swift's GameStore (that file needs the rest of the app).
enum GameStore: String, CaseIterable, Identifiable, Hashable {
    case steam, epic, gog, itch, amazon, ea
    var id: String { rawValue }
    var title: String { switch self { case .steam: "Steam"; case .epic: "Epic Games"; case .gog: "GOG"; case .itch: "itch.io"; case .amazon: "Amazon Games"; case .ea: "EA app" } }
    var tint: Color {
        switch self {
        case .steam: Color(red: 0.40, green: 0.62, blue: 0.82)
        case .epic: Color(red: 0.75, green: 0.78, blue: 0.84)
        case .gog: Color(red: 0.62, green: 0.36, blue: 0.80)
        case .itch: Color(red: 0.98, green: 0.36, blue: 0.36)
        case .amazon: Color(red: 1.0, green: 0.60, blue: 0.0)
        case .ea: Color(red: 1.0, green: 0.30, blue: 0.27)
        }
    }
}
