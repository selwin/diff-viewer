import Foundation

/// What the branch picker reads from a window. Read-only, like `+Presentation`.
extension WindowState {
    /// An open window with a repository, and no commit sheet or commit picker up: the
    /// popover never opens over another one.
    var canOpenBranchPicker: Bool {
        session != nil && !isClosed && !isCommitSheetPresented && !isCommitPickerPresented
    }

    var branchPickerSnapshot: BranchPickerSnapshot {
        BranchPickerSnapshot(
            headState: headState, branches: branches, readStatus: branchReadStatus,
            isSwitchingBranch: isSwitchingBranch, fetchStatus: fetchStatus,
            activeSyncOperation: activeSyncOperation, fetchingRemotes: fetchingRemotes, remotes: remotes,
            configuredUpstreamRemotes: configuredUpstreamRemotes, secondaryFetchFailures: secondaryFetchFailures)
    }
}
