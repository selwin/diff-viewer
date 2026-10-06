import Testing

@testable import DiffViewer

/// What the title bar pill's Pull and Push segments show for the current branch.
struct CurrentBranchSyncPresentationTests {
    private static func snapshot(
        headState: HeadState? = .named("main"), branches: [LocalBranch], readStatus: BranchReadStatus = .loaded,
        activeSync: ActiveSync? = nil, fetchingRemotes: Set<String> = [], remotes: [String] = ["origin"],
        configuredUpstreamRemotes: [String: String] = [:]
    ) -> BranchPickerSnapshot {
        BranchPickerSnapshot(
            headState: headState, branches: branches, readStatus: readStatus, isSwitchingBranch: false,
            activeSync: activeSync, fetchingRemotes: fetchingRemotes, remotes: remotes,
            configuredUpstreamRemotes: configuredUpstreamRemotes)
    }

    private static func tracking(ahead: Int, behind: Int) -> LocalBranch {
        localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: ahead, behind: behind)))
    }

    @Test(
        arguments: [
            // Detached: no branch to sync.
            snapshot(headState: .detached(sha: objectID("x")), branches: [tracking(ahead: 1, behind: 0)]),
            // HEAD's branch isn't in the list, so nothing is known about its upstream.
            snapshot(branches: [localBranch("other")]),
            // A failed read keeps a stale HEAD and list.
            snapshot(branches: [tracking(ahead: 1, behind: 0)], readStatus: .failed),
        ])
    func noPresentationWithoutAListedCurrentBranch(taken: BranchPickerSnapshot) {
        #expect(CurrentBranchSyncPresentation.make(snapshot: taken) == nil)
    }

    @Test(
        arguments: [(BranchPickerSnapshot, RowSyncButtons, Int?, Int?)]([
            // In sync: no segments.
            (snapshot(branches: [tracking(ahead: 0, behind: 0)]), .hidden, nil, nil),
            // Behind only.
            (
                snapshot(branches: [tracking(ahead: 0, behind: 1)]),
                RowSyncButtons(pull: .enabled, push: .hidden), 1, nil
            ),
            // Diverged: both show, and Push waits for the pull.
            (
                snapshot(branches: [tracking(ahead: 2, behind: 1)]),
                RowSyncButtons(pull: .enabled, push: .disabled(reason: "Pull first")), 1, 2
            ),
            // Untracked: Publish in Push's place, with nothing to count.
            (
                snapshot(branches: [localBranch("main")]),
                RowSyncButtons(pull: .hidden, push: .enabled, pushOperation: .publish, publish: .remote("origin")),
                nil, nil
            ),
            // Untracked with no remotes: nowhere to publish.
            (snapshot(branches: [localBranch("main")], remotes: []), .hidden, nil, nil),
            // An upstream the fetch settings hide: Publish would rewrite it.
            (
                snapshot(branches: [localBranch("main")], configuredUpstreamRemotes: ["main": "origin"]),
                RowSyncButtons(
                    pull: .hidden, push: .disabled(reason: "Tracks origin, but fetch settings don't fetch it"),
                    pushOperation: .publish),
                nil, nil
            ),
            // A push whose refresh already zeroed the counts keeps its spinner, with no count.
            (
                snapshot(
                    branches: [tracking(ahead: 0, behind: 0)],
                    activeSync: ActiveSync(branch: "main", operation: .push)),
                RowSyncButtons(pull: .hidden, push: .running), nil, nil
            ),
        ]))
    func segmentsFollowTheSyncRules(
        taken: BranchPickerSnapshot, buttons: RowSyncButtons, pullCount: Int?, pushCount: Int?
    ) throws {
        let sync = try #require(CurrentBranchSyncPresentation.make(snapshot: taken))
        #expect(sync.branch == "main")
        #expect(sync.buttons == buttons)
        #expect(sync.pullCount == pullCount)
        #expect(sync.pushCount == pushCount)
    }

    struct PushActionCase: CustomTestStringConvertible {
        let name: String
        let snapshot: BranchPickerSnapshot
        let expectedAction: CurrentBranchSyncPresentation.PushAction?

        var testDescription: String { name }
    }

    static let pushActionCases: [PushActionCase] = [
        PushActionCase(
            name: "hidden", snapshot: snapshot(branches: [tracking(ahead: 0, behind: 0)]), expectedAction: nil),
        PushActionCase(
            name: "disabled", snapshot: snapshot(branches: [tracking(ahead: 2, behind: 1)]), expectedAction: nil),
        PushActionCase(
            name: "running",
            snapshot: snapshot(
                branches: [tracking(ahead: 1, behind: 0)], activeSync: ActiveSync(branch: "main", operation: .push)),
            expectedAction: nil),
        PushActionCase(
            name: "push", snapshot: snapshot(branches: [tracking(ahead: 1, behind: 0)]), expectedAction: .push),
        PushActionCase(
            name: "publish to the only remote", snapshot: snapshot(branches: [localBranch("main")], remotes: ["fork"]),
            expectedAction: .publish(remote: "fork")),
        // Without origin there is no remote to pick automatically.
        PushActionCase(
            name: "choose among remotes without origin",
            snapshot: snapshot(
                branches: [localBranch("main")], fetchingRemotes: ["upstream"], remotes: ["fork", "upstream"]),
            expectedAction: .chooseRemote(remotes: [
                PublishMenuItem(remote: "fork", isEnabled: true), PublishMenuItem(remote: "upstream", isEnabled: false),
            ])),
    ]

    @Test(arguments: pushActionCases)
    func pushActionIsWhatAnEnabledPushSlotDoes(_ testCase: PushActionCase) throws {
        let sync = try #require(CurrentBranchSyncPresentation.make(snapshot: testCase.snapshot))
        #expect(sync.pushAction == testCase.expectedAction)
    }

    @Test func departureKeepsDrawingASegmentThatWentHidden() {
        let pulling = CurrentBranchSyncPresentation(
            branch: "main", buttons: RowSyncButtons(pull: .running, push: .disabled(reason: "Pulling…")), target: nil)
        let pulled = CurrentBranchSyncPresentation(
            branch: "main", buttons: RowSyncButtons(pull: .hidden, push: .enabled), target: nil)
        let departure = SegmentDeparture.between(pulling, pulled)
        #expect(departure == SegmentDeparture(previous: pulling, pull: true, push: false))
        // The departing Pull keeps its spinner; the Push that stayed shows its live state.
        #expect(departure?.applied(to: pulled).buttons == RowSyncButtons(pull: .running, push: .enabled))

        // Back in the live presentation, the segment is drawn live again.
        let behindAgain = CurrentBranchSyncPresentation(
            branch: "main", buttons: RowSyncButtons(pull: .enabled, push: .enabled), target: nil)
        #expect(departure?.applied(to: behindAgain).buttons == behindAgain.buttons)

        // Nothing went hidden, or the branch changed: nothing departs.
        #expect(SegmentDeparture.between(pulled, pulled) == nil)
        let other = CurrentBranchSyncPresentation(branch: "other", buttons: .hidden, target: nil)
        #expect(SegmentDeparture.between(pulling, other) == nil)
    }
}
