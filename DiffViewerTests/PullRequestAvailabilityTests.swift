import Testing

@testable import DiffViewer

/// When Create Pull Request shows, and when it can act.
struct PullRequestAvailabilityTests {
    private static func tracking(
        remote: String = "origin", remoteRef: String = "refs/heads/main",
        tracking: UpstreamTracking = .counts(ahead: 0, behind: 0)
    ) -> LocalBranch {
        localBranch(
            "main", upstream: upstream("\(remote)/main", remote: remote, remoteRef: remoteRef, tracking: tracking))
    }

    private static func snapshot(
        headState: HeadState? = .named("main"), branches: [LocalBranch] = [tracking()],
        readStatus: BranchReadStatus = .loaded, isSwitchingBranch: Bool = false, isCommitting: Bool = false,
        activeSync: ActiveSync? = nil, gitHubRemoteNames: Set<String> = ["origin"]
    ) -> BranchPickerSnapshot {
        BranchPickerSnapshot(
            headState: headState, branches: branches, readStatus: readStatus, isSwitchingBranch: isSwitchingBranch,
            isCommitting: isCommitting, activeSync: activeSync, gitHubRemoteNames: gitHubRemoteNames)
    }

    @Test(
        arguments: [
            (snapshot(readStatus: .failed), true),
            (snapshot(headState: .detached(sha: objectID("x"))), true),
            (snapshot(branches: [localBranch("other")]), true),
            (snapshot(branches: [localBranch("main")]), true),
            (snapshot(branches: [tracking(tracking: .gone)]), true),
            (snapshot(branches: [tracking(remoteRef: "refs/tags/main")]), true),
            (snapshot(branches: [tracking(remote: "gitlab")]), true),
            (snapshot(), false),
        ] as [(BranchPickerSnapshot, Bool)])
    func hiddenWithoutAGitHubBranchUpstreamOrAnEligibleWindow(snapshot: BranchPickerSnapshot, isEligible: Bool) {
        #expect(PullRequestAvailability.make(snapshot: snapshot, isWindowEligible: isEligible) == .hidden)
    }

    @Test(
        arguments: [
            (snapshot(branches: [tracking(tracking: .counts(ahead: 1, behind: 0))]), .disabled(help: "Push first")),
            // What holds the repository is the news while it runs.
            (
                snapshot(
                    branches: [tracking(tracking: .counts(ahead: 1, behind: 0))],
                    activeSync: ActiveSync(branch: "main", operation: .push)),
                .disabled(help: "Pushing main…")
            ),
            // Behind is fine: the pull request shows what was pushed.
            (snapshot(branches: [tracking(tracking: .counts(ahead: 0, behind: 4))]), .enabled),
        ] as [(BranchPickerSnapshot, PullRequestAvailability)])
    func shownWhenTheBranchTracksAGitHubBranch(snapshot: BranchPickerSnapshot, expected: PullRequestAvailability) {
        #expect(PullRequestAvailability.make(snapshot: snapshot, isWindowEligible: true) == expected)
    }

    @Test func theHeaderOffersOnlyAnEnabledPullRequestToTab() {
        let enabled = BranchPickerHeaderText.make(snapshot: Self.snapshot())
        #expect(enabled.pullRequest == .enabled)
        #expect(enabled.focusOrder == [.copy, .fetch, .pullRequest])
        let unpushed = BranchPickerHeaderText.make(
            snapshot: Self.snapshot(branches: [Self.tracking(tracking: .counts(ahead: 1, behind: 0))]))
        #expect(unpushed.focusOrder == [.copy, .fetch, .push])
    }
}
