import Foundation

/// A comparison tab's scene value. It only names the coordinator's pending request, so
/// the range itself never passes through SwiftUI.
struct ComparisonToken: Hashable, Codable, Sendable {
    let id: UUID

    init() {
        id = UUID()
    }
}
