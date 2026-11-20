import Foundation
/// Stand-in for the app's Game: BindSets.swift extends it, and the default-controls picture only needs the layouts from that file.
struct Game { var bindSets: [BindSet]?; var activeBindSetID: UUID? }
