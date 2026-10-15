import Foundation

/// Which repository window a Compare window belongs to. `WindowGroup` opens one window per
/// distinct value, so opening it again for the same window brings the existing one forward.
struct CompareWindowTarget: Hashable, Codable, Sendable {
    let owner: WindowID
}
