import Foundation
import Testing

@testable import DiffViewer

/// When the pull request button shows, whether it creates or views, and when it can act.
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

    private static let pullRequest = GitHubPullRequest(
        number: 7, url: URL(string: "https://github.com/me/widgets/pull/7")!)
    private static let remotes = [
        "origin": RemoteURLs(fetchURL: "git@github.com:me/widgets.git", pushURLs: ["git@github.com:me/widgets.git"])
    ]

    /// `snapshot` with a lookup for `lookupBranch` and HEAD's identity from `snapshot`'s branch.
    private static func viewing(
        _ snapshot: BranchPickerSnapshot, lookupBranch: LocalBranch = tracking(),
        pullRequest: GitHubPullRequest? = pullRequest
    ) throws -> BranchPickerSnapshot {
        var snapshot = snapshot
        let identity = try #require(PullRequestIdentity.make(branch: lookupBranch, remotes: remotes))
        snapshot.pullRequestLookup = PullRequestLookup(identity: identity, pullRequest: pullRequest)
        snapshot.currentPullRequestIdentity = snapshot.branches.first.flatMap {
            PullRequestIdentity.make(branch: $0, remotes: remotes)
        }
        return snapshot
    }

    @Test func anOpenPullRequestForHeadsIdentityIsViewedEvenWhileAheadOrBusy() throws {
        let ahead = Self.tracking(tracking: .counts(ahead: 1, behind: 0))
        for snapshot in [
            Self.snapshot(),
            Self.snapshot(branches: [ahead]),
            Self.snapshot(isSwitchingBranch: true),
            Self.snapshot(activeSync: ActiveSync(branch: "main", operation: .pull)),
        ] {
            #expect(
                PullRequestAvailability.make(snapshot: try Self.viewing(snapshot), isWindowEligible: true)
                    == .view(Self.pullRequest))
        }
        // Another identity's PR, no PR, or no lookup at all: back to creating.
        let other = Self.tracking(remoteRef: "refs/heads/other")
        for snapshot in [
            try Self.viewing(Self.snapshot(), lookupBranch: other), try Self.viewing(Self.snapshot(), pullRequest: nil),
            Self.snapshot(),
        ] {
            #expect(PullRequestAvailability.make(snapshot: snapshot, isWindowEligible: true) == .enabled)
        }
        #expect(
            PullRequestAvailability.make(snapshot: try Self.viewing(Self.snapshot()), isWindowEligible: false)
                == .hidden)
    }

    @Test func theTitleAndLabelFollowTheAvailability() {
        let view = PullRequestAvailability.view(Self.pullRequest)
        #expect(view.title == "PR #7")
        #expect(view.accessibilityLabel(branchName: "main") == "View pull request #7 on GitHub")
        #expect(view.isActionable)
        #expect(view.pickerButtonState == .enabled)
        for creating in [PullRequestAvailability.enabled, .disabled(help: "Push first")] {
            #expect(creating.title == "Open PR")
            #expect(creating.accessibilityLabel(branchName: "main") == "Create a pull request for main on GitHub")
        }
        #expect(PullRequestAvailability.enabled.isActionable)
        #expect(!PullRequestAvailability.disabled(help: "Push first").isActionable)
    }

    @Test func theHeaderOffersOnlyAnEnabledPullRequestToTab() {
        let enabled = BranchPickerHeaderText.make(snapshot: Self.snapshot())
        #expect(enabled.pullRequest == .enabled)
        #expect(enabled.focusOrder == [.copy, .fetch, .pullRequest])
        let unpushed = BranchPickerHeaderText.make(
            snapshot: Self.snapshot(branches: [Self.tracking(tracking: .counts(ahead: 1, behind: 0))]))
        #expect(unpushed.focusOrder == [.copy, .fetch, .push])
    }

    @Test func theHeaderLeavesAnExistingPullRequestToTheRowCapsule() throws {
        let header = BranchPickerHeaderText.make(snapshot: try Self.viewing(Self.snapshot()))
        #expect(header.pullRequest == .hidden)
        #expect(header.focusOrder == [.copy, .fetch])
    }
}
