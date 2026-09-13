import Foundation

/// What the sidebar and the diffs are computed against: the working tree, as the app
/// has always shown, or one previous commit.
///
/// A commit scope holds only the `CommitRef`, never a `CommitSummary`: display metadata
/// is refreshed on every history read, and selection must not change when a subject or
/// an abbreviation does.
enum DiffScope: Hashable, Sendable {
    case workingTree
    case commit(CommitRef)

    /// The areas whose line counts this scope needs.
    var areas: [ChangedFile.Area] {
        switch self {
        case .workingTree: [.unstaged, .staged]
        case let .commit(ref): [.commit(ref)]
        }
    }
}
