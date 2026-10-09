import Foundation

/// What the branch picker, the New Branch sheet and the Merge sheet read from a window, and
/// how the picker hands over to them.
extension WindowState {
    /// An open window with a repository, and no commit sheet, commit picker, New Branch
    /// sheet or Merge sheet up: the popover never opens over another one.
    var canOpenBranchPicker: Bool {
        session != nil && !isClosed && !isOtherOverlayPresented(besides: .branchPicker)
    }

    /// Like `canOpenBranchPicker`, with the branch picker down too and no switch queued or
    /// running: the new branch starts at HEAD, which a switch is about to move.
    var canOpenNewBranchSheet: Bool {
        session != nil && !isClosed && !isSwitchingBranch && !isOtherOverlayPresented(besides: .newBranchSheet)
            && !isNewBranchSheetPresented
    }

    /// The picker's New Branch… row and ⌘N: the popover closes first, since only one of
    /// them is up at a time. The sheet opens with `initialName` filled in.
    func openNewBranchSheet(initialName: String?) {
        isBranchPickerPresented = false
        guard canOpenNewBranchSheet else { return }
        newBranchInitialName = initialName
        isNewBranchSheetPresented = true
    }

    /// The sheet is gone, by Create or Cancel: the next one opens with its own name.
    func newBranchSheetDismissed() {
        newBranchInitialName = nil
    }

    /// What the New Branch sheet names as the branch it starts from.
    var newBranchBaseTitle: String {
        switch headState {
        case let .named(name): name
        case .detached: "Detached HEAD"
        case nil: "Current branch"
        }
    }

    /// HEAD's commit for the New Branch sheet, or nil when it can't be told for sure. Branch
    /// state and history refresh separately, so after an outside checkout the history's
    /// first commit may still be the old branch's tip.
    var newBranchBaseCommit: CommitSummary? {
        let tip: String? =
            switch headState {
            case .named: currentBranch?.tipSha
            case let .detached(sha): sha
            case nil: nil
            }
        guard let tip, let commit = history.commits.first, commit.ref.sha == tip else { return nil }
        return commit
    }

    /// Like `canOpenNewBranchSheet`: a merge changes the branch HEAD is on, which a queued
    /// switch is about to move.
    var canOpenMergeSheet: Bool {
        session != nil && !isClosed && !isSwitchingBranch && !isOtherOverlayPresented(besides: .mergeSheet)
            && pendingMerge == nil
    }

    /// A Merge row in the picker: the popover closes first, as for New Branch….
    func openMergeSheetFromPicker(_ target: MergeTarget) {
        isBranchPickerPresented = false
        guard canOpenMergeSheet else { return }
        pendingMerge = target
    }

    /// Whether `name` is a local branch as of the last read. Git refuses one created since.
    func hasLocalBranch(named name: String) -> Bool {
        branches.contains { $0.name == name }
    }

    /// Git's verdict on `name` as a new branch. A check git could not run counts as
    /// invalid: creating would fail the same way.
    func isValidBranchName(_ name: String) async -> Bool {
        guard let session, !isClosed else { return false }
        return (try? await session.client.isValidBranchName(name)) ?? false
    }

    var branchPickerSnapshot: BranchPickerSnapshot {
        BranchPickerSnapshot(
            headState: headState, branches: branches, readStatus: branchReadStatus,
            isSwitchingBranch: isSwitchingBranch, isCommitting: isCommitting, fetchStatus: fetchStatus,
            activeSync: activeSync, fetchingRemotes: fetchingRemotes, remotes: remotes,
            configuredUpstreamRemotes: configuredUpstreamRemotes, lastFetchRound: lastFetchRound,
            remoteBranches: remoteBranches, newRemoteBranches: newRemoteBranches)
    }
}
