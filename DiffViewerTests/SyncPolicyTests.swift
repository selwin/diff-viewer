import Foundation
import Testing

@testable import DiffViewer

/// What the picker may offer, and what it may do, for a given branch read.
struct SyncPolicyTests {
    private func tracked(ahead: Int, behind: Int, name: String = "main") -> LocalBranch {
        localBranch(name, upstream: upstream("origin/\(name)", tracking: .counts(ahead: ahead, behind: behind)))
    }

    private func target(
        _ readStatus: BranchReadStatus = .loaded, head: HeadState? = .named("main"), branches: [LocalBranch]
    ) -> SyncTarget? {
        SyncPolicy.target(readStatus: readStatus, headState: head, branches: branches)
    }

    // MARK: Target

    @Test func aLoadedReadOnATrackedBranchNamesTheDestination() {
        let resolved = target(branches: [tracked(ahead: 1, behind: 2)])
        #expect(
            resolved
                == SyncTarget(
                    destination: SyncDestination(branch: "main", remote: "origin", remoteRef: "refs/heads/main"),
                    ahead: 1, behind: 2))
    }

    @Test func anythingLessThanALoadedTrackedBranchHasNoTarget() {
        let branches = [tracked(ahead: 1, behind: 1)]
        #expect(target(.unread, branches: branches) == nil)
        #expect(target(.failed, branches: branches) == nil)
        #expect(target(head: nil, branches: branches) == nil)
        #expect(target(head: .detached(sha: objectID("x")), branches: branches) == nil)
        #expect(target(head: .named("other"), branches: branches) == nil, "HEAD is not in the list")
        #expect(target(branches: [localBranch("main")]) == nil, "no upstream")
        #expect(
            target(branches: [localBranch("main", upstream: upstream("origin/main", tracking: .gone))]) == nil,
            "a gone upstream says nothing about where a push would go")
    }

    // MARK: Permission

    @Test func pullNeedsCommitsToTakeAndPushAFastForward() {
        func target(ahead: Int, behind: Int) -> SyncTarget {
            SyncTarget(
                destination: SyncDestination(branch: "main", remote: "origin", remoteRef: "refs/heads/main"),
                ahead: ahead, behind: behind)
        }
        #expect(SyncPolicy.allows(.pull, on: target(ahead: 0, behind: 1)))
        #expect(!SyncPolicy.allows(.pull, on: target(ahead: 3, behind: 0)))
        #expect(SyncPolicy.allows(.push, on: target(ahead: 1, behind: 0)))
        #expect(!SyncPolicy.allows(.push, on: target(ahead: 0, behind: 0)))
        #expect(!SyncPolicy.allows(.push, on: target(ahead: 1, behind: 1)), "diverged: pull first")
    }

    // MARK: Buttons

    private func buttons(
        ahead: Int, behind: Int, active: SyncOperation? = nil, isSwitching: Bool = false, isFetching: Bool = false
    ) -> (pull: PickerButtonState, push: PickerButtonState) {
        SyncPolicy.buttons(
            target: target(branches: [tracked(ahead: ahead, behind: behind)]), active: active,
            isSwitching: isSwitching, isFetching: isFetching)
    }

    @Test func theCountsDecideWhichButtonsShow() {
        #expect(buttons(ahead: 0, behind: 0) == (.hidden, .hidden), "in sync")
        #expect(buttons(ahead: 0, behind: 2) == (.enabled, .hidden))
        #expect(buttons(ahead: 2, behind: 0) == (.hidden, .enabled))
        #expect(buttons(ahead: 1, behind: 2) == (.enabled, .disabled(reason: "Pull first")))
        let untracked = SyncPolicy.buttons(
            target: target(branches: [localBranch("main")]), active: nil, isSwitching: false, isFetching: false)
        #expect(untracked == (.hidden, .hidden))
    }

    @Test func aSwitchOrAFetchDisablesWhateverWouldShow() {
        let switching = PickerButtonState.disabled(reason: "Switching branch…")
        #expect(buttons(ahead: 1, behind: 2, isSwitching: true) == (switching, switching))
        #expect(buttons(ahead: 0, behind: 2, isFetching: true) == (.disabled(reason: "Fetching…"), .hidden))
        #expect(buttons(ahead: 0, behind: 0, isFetching: true) == (.hidden, .hidden), "nothing to disable")
    }

    /// The button the reader clicked keeps its spinner while the operation's own refresh
    /// moves the counts under it, or takes the target away entirely. The other button
    /// shows, disabled, only where the counts would show it anyway.
    @Test func theOperationInFlightOutranksTheCounts() {
        #expect(buttons(ahead: 0, behind: 2, active: .pull) == (.running, .hidden))
        #expect(buttons(ahead: 2, behind: 0, active: .push) == (.hidden, .running))
        // Diverged: Push was already up as "Pull first", so it stays up while the pull runs.
        #expect(buttons(ahead: 1, behind: 2, active: .pull) == (.running, .disabled(reason: "Pulling…")))
        #expect(buttons(ahead: 2, behind: 1, active: .push) == (.disabled(reason: "Pushing…"), .running))
        // The pull finished the counts it was started for, and the target is gone.
        let vanished = SyncPolicy.buttons(target: nil, active: .pull, isSwitching: false, isFetching: false)
        #expect(vanished == (.running, .hidden))
        #expect(buttons(ahead: 0, behind: 0, active: .push, isSwitching: true) == (.hidden, .running))
    }
}
