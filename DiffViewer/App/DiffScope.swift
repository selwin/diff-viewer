import Foundation

/// What the sidebar and the diffs are computed against: the working tree, as the app
/// has always shown, one previous commit, or a branch against its merge base.
///
/// A commit scope holds only the `CommitRef`, never a `CommitSummary`: display metadata
/// is refreshed on every history read, and selection must not change when a subject or
/// an abbreviation does.
enum DiffScope: Hashable, Sendable {
    case workingTree
    case commit(CommitRef)
    case range(CommitRange)

    /// The areas whose line counts this scope needs.
    var areas: [ChangedFile.Area] {
        switch self {
        case .workingTree: return [.unstaged, .staged]
        case let .commit(ref):
            var areas: [ChangedFile.Area] = [.commit(ref)]
            if let untracked = ref.untrackedCommit { areas.append(.commit(untracked)) }
            return areas
        case let .range(range): return [.range(range)]
        }
    }
}
