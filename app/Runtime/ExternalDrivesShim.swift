// Porthole: upstream's ExternalDrives.swift is a SwiftUI file of Madeira's own library; the Dock code only reads this one list from it.
// Porthole's SSD library (ExternalLibrary.swift, PR #235 model) is reached through drive_c/E: instead, so there are no upstream external Steam libraries here.
import Foundation

enum ExternalDrives {
    static var steamLibraries: [String] { [] }
}
