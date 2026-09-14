import Foundation

/// The values the sidebar and the title bar derive from a window's state.
///
/// An extension in its own file: none of this writes anything — each member only reads
/// what the class already holds — so it does not need to sit next to the mutating code,
/// and SwiftLint caps a file at 600 lines.
extension WindowState {
    /// A path to find again in a new scope, and the area it came from.
    struct PendingSelection: Equatable, Sendable {
        let path: String
        let area: ChangedFile.Area
        /// Where the file sat in sidebar order, used only when the path is gone from the
        /// new list: discarding or trashing the selected row leaves nothing to match, and
        /// the reader expects the row that took its place. Nil for a scope change, where
        /// the two lists describe different commits and an index means nothing.
        var row: Int?
    }

    /// What the picker shows in place of a commit list.
    enum HistoryPlaceholder {
        case loading
        case empty
        case failed
    }

    /// Nil when there are commits to list.
    var historyPlaceholder: HistoryPlaceholder? {
        guard history.commits.isEmpty else { return nil }
        if isLoadingHistory { return .loading }
        return historyErrorMessage == nil ? .empty : .failed
    }

    /// The window subtitle: the current branch, or where a detached HEAD sits. The
    /// selected file's path is not here — the detail header already shows it, larger.
    var subtitle: String {
        switch headState {
        case let .named(name)?: name
        case let .detached(sha)?: "detached at " + sha.prefix(7)
        case nil: ""
        }
    }
}
