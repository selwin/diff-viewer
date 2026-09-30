import Testing

@testable import DiffViewer

/// What the title bar pill's Pull and Push segments show for the current branch.
struct CurrentBranchSyncPresentationTests {
    private static func snapshot(
        headState: HeadState? = .named("main"), branches: [LocalBranch], readStatus: BranchReadStatus = .loaded,
        activeSync: ActiveSync? = nil, remotes: [String] = ["origin"], configuredUpstreamRemotes: [String: String] = [:]
    ) -> BranchPickerSnapshot {
        BranchPickerSnapshot(
            headState: headState, branches: branches, readStatus: readStatus, isSwitchingBranch: false,
            activeSync: activeSync, remotes: remotes, configuredUpstreamRemotes: configuredUpstreamRemotes)
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
}
