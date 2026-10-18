import Foundation
// Stand-ins for app code that the Steam sources reach but the Mac test build does not compile (the real StoreNetwork is in Sources/Core).
enum StoreNetwork {
    static let session = URLSession(configuration: .ephemeral)
}
