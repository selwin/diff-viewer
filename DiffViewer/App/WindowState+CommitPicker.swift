import Foundation

/// What the commit picker reads from a window. Read-only, like `+Presentation`.
extension WindowState {
    /// An open window with a repository, and no commit sheet, branch picker or New Branch
    /// sheet up: the popover never opens over another one.
    var canOpenCommitPicker: Bool {
        session != nil && !isClosed && !isOtherOverlayPresented(besides: .commitPicker)
    }

    /// The displayed commit is the page's copy when the page carries it, the freshest
    /// read, and otherwise the one held since it was selected.
    var commitPickerSnapshot: CommitPickerSnapshot {
        let displayedCommit: CommitSummary? =
            if case let .commit(ref) = scope { history.commits.first { $0.ref == ref } ?? selectedCommit } else { nil }
        return CommitPickerSnapshot(
            displayedScope: scope,
            displayedCommit: displayedCommit,
            commits: history.commits,
            hasMore: history.hasMore,
            isLoadingHistory: isLoadingHistory,
            historyLoadFailed: historyErrorMessage != nil,
            workingTreeChangeCount: workingTreeChurn?.changedFileCount,
            unpushedShas: unpushedCommitShas)
    }
}
