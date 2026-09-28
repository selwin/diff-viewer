import Foundation

/// What the commit picker reads from a window. Read-only, like `+Presentation`.
extension WindowState {
    /// An open window with a repository, and no commit sheet, branch picker or New Branch
    /// sheet up: the popover never opens over another one.
    var canOpenCommitPicker: Bool {
        session != nil && !isClosed && !isCommitSheetPresented && !isBranchPickerPresented
            && !isNewBranchSheetPresented
    }

    /// Distinct paths in the displayed scope: a file both staged and unstaged counts once.
    /// Nil while the list is being read or the last read failed, when an empty list means
    /// unread, not clean.
    var displayedScopeFileCount: Int? {
        guard !isLoadingScope, !listReadFailed else { return nil }
        return Self.distinctPathCount(files)
    }

    var commitPickerSnapshot: CommitPickerSnapshot {
        let displayedCommit: CommitSummary? =
            if case let .commit(ref) = scope { selectableCommits.first { $0.ref == ref } } else { nil }
        return CommitPickerSnapshot(
            displayedScope: scope,
            displayedCommit: displayedCommit,
            commits: selectableCommits,
            hasMore: history.hasMore,
            isLoadingHistory: isLoadingHistory,
            historyLoadFailed: historyErrorMessage != nil,
            displayedScopeFileCount: displayedScopeFileCount)
    }

    /// The displayed commit is the page's copy when the page carries it, the freshest
    /// read, and otherwise the one held since it was selected.
    var commitPickerListSnapshot: CommitPickerListSnapshot {
        let displayedCommit: CommitSummary? =
            if case let .commit(ref) = scope { history.commits.first { $0.ref == ref } ?? selectedCommit } else { nil }
        return CommitPickerListSnapshot(
            displayedScope: scope,
            displayedCommit: displayedCommit,
            commits: history.commits,
            hasMore: history.hasMore,
            isLoadingHistory: isLoadingHistory,
            historyLoadFailed: historyErrorMessage != nil,
            workingTreeChangeCount: workingTreeChangeCount,
            unpushedShas: unpushedCommitShas)
    }
}
