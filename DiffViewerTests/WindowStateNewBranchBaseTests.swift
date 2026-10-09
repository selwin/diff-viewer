import Testing

@testable import DiffViewer

/// The commit the New Branch sheet names as the base, when branch state and history agree.
@MainActor
struct WindowStateNewBranchBaseTests {
    /// A window adopted with HEAD at `headState`, `branches` listed and `commits` as its
    /// history, waited on past the branch and history reads so `newBranchBaseCommit` is settled.
    /// The window is returned whole so its harness outlives the test body.
    private func settled(headState: HeadState, branches: [LocalBranch], commits: [CommitSummary]) async -> Window {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: [changedFile("a.swift")]) { client in
            await client.set(headState: headState)
            await client.set(localBranches: branches)
            await client.set(head: commits.first?.ref.sha)
            await client.set(commits: commits)
        }
        #expect(await eventually { await state.headState == headState })
        #expect(state.branches == branches)
        #expect(await eventually { await repo.client.headCalls > 0 })
        #expect(await eventually { await !state.isLoadingHistory })
        #expect(state.history.commits.map(\.ref.sha) == commits.map(\.ref.sha))
        return (h, state, repo.client, repo.root)
    }

    @Test func aNamedHeadAtTheHistorysFirstCommitIsTheBase() async {
        let tip = commitSummary("tip")
        let (_, state, _, _) = await settled(
            headState: .named("main"), branches: [localBranch("main", tipSha: tip.ref.sha)], commits: [tip])

        #expect(state.newBranchBaseCommit?.ref.sha == tip.ref.sha)
    }

    @Test func aDetachedHeadAtTheHistorysFirstCommitIsTheBase() async {
        let tip = commitSummary("tip")
        let (_, state, _, _) = await settled(
            headState: .detached(sha: tip.ref.sha), branches: [localBranch("main")], commits: [tip])

        #expect(state.newBranchBaseCommit?.ref.sha == tip.ref.sha)
    }

    /// An outside checkout moved HEAD to another branch before the history was re-read.
    @Test func aHistoryFromAnotherTipHasNoBase() async {
        let (_, state, _, _) = await settled(
            headState: .named("feature"),
            branches: [localBranch("main"), localBranch("feature", tipSha: objectID("feature-tip"))],
            commits: [commitSummary("main-tip")])

        #expect(state.newBranchBaseCommit == nil)
    }

    @Test func anUnbornHeadHasNoBase() async {
        let (_, state, _, _) = await settled(headState: .named("main"), branches: [], commits: [])

        #expect(state.newBranchBaseCommit == nil)
    }
}
