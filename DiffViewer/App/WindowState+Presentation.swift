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

    static let scopeSelectionHelp = "Choose what to compare: the working tree, or a commit against its parent"

    /// The branch picker's face: the current branch, or where a detached HEAD sits.
    var branchDisplayTitle: String {
        switch headState {
        case let .named(name)?: name
        case let .detached(sha)?: "Detached " + sha.prefix(7)
        case nil: ""
        }
    }

    /// The branch picker's suffix: how far the current branch is from its upstream, or
    /// nil when in sync, untracked, or detached. Counts are as old as the last fetch.
    var branchTrackingSummary: String? {
        currentBranch?.tracking?.summary
    }

    /// The branch picker's help: the upstream, named whenever there is one, and where the
    /// branch stands against it.
    var branchSwitchHelp: String {
        let base = "Switch branch"
        guard let branch = currentBranch, let upstream = branch.upstream else { return base }
        let detail = branch.tracking == .gone ? "gone" : (branch.tracking?.summary ?? "up to date")
        return "\(base) · \(upstream): \(detail)"
    }

    /// The branch picker's selection: nil while HEAD is detached or unread.
    var currentBranchName: String? {
        if case let .named(name)? = headState { return name }
        return nil
    }

    /// The scope picker's face: the working tree, or the selected commit's subject and
    /// short SHA. The SHA alone when the commit's summary is not held.
    var scopeDisplayTitle: String {
        switch scope {
        case .workingTree: "Working Tree"
        case let .commit(ref):
            if let subject = selectedCommit?.subject { "\(subject) · \(ref.shortSha)" } else { ref.shortSha }
        }
    }
}
