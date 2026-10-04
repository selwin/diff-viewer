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
    /// them is up at a time.
    func openNewBranchSheetFromPicker() {
        isBranchPickerPresented = false
        guard canOpenNewBranchSheet else { return }
        isNewBranchSheetPresented = true
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
            isSwitchingBranch: isSwitchingBranch, fetchStatus: fetchStatus,
            activeSync: activeSync, fetchingRemotes: fetchingRemotes, remotes: remotes,
            configuredUpstreamRemotes: configuredUpstreamRemotes, lastFetchRound: lastFetchRound,
            remoteBranches: remoteBranches, newRemoteBranches: newRemoteBranches)
    }
}
