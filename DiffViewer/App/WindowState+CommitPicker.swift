import Foundation

/// What the commit picker reads from a window. Read-only, like `+Presentation`.
extension WindowState {
    /// An open window with a repository, and no commit sheet up: the popover never opens over the sheet.
    var canOpenCommitPicker: Bool {
        session != nil && !isClosed && !isCommitSheetPresented
    }

    /// Distinct paths in the displayed scope: a file both staged and unstaged counts once.
    /// Nil while the list is being read or the last read failed, when an empty list means
    /// unread, not clean.
    var displayedScopeFileCount: Int? {
        guard !isLoadingScope, !listReadFailed else { return nil }
        return Set(files.map(\.path)).count
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
}
