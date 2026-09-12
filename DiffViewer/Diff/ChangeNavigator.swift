import Foundation

/// Index math for stepping through change blocks.
enum ChangeNavigator {
    static func next(after current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return min(current + 1, count - 1)
    }

    static func previous(before current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return max(current - 1, 0)
    }

    /// Keeps an index valid after the block list changes length.
    static func clamp(_ index: Int?, count: Int) -> Int? {
        guard let index, count > 0 else { return nil }
        return min(index, count - 1)
    }
}

/// A one-shot request for the diff view to scroll to a row.
struct ScrollTarget: Equatable, Sendable {
    let id = UUID()
    let row: Int
}
