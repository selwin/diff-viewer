import Testing

@testable import DiffViewer

/// What the branch picker's subtitle and help say about the current branch's upstream.
@MainActor
struct WindowStateBranchTrackingTests {
    /// A window adopted with `branches` in the list and HEAD at `headState`, waited on
    /// past the first file list and the branch read, so the picker's values are settled.
    private typealias Window = (h: Harness, state: WindowState, client: StubRepoClient, root: RepositoryRoot)

    private func settled(branches: [LocalBranch], headState: HeadState) async throws -> Window {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: [changedFile("a.swift")])
        await repo.client.set(localBranches: branches)
        await repo.client.set(headState: headState)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count == 1 })
        #expect(await eventually { await state.localBranches == branches.map(\.name) })
        #expect(state.headState == headState)
        return (h, state, repo.client, repo.root)
    }

    @Test(
        arguments: [(LocalBranch, HeadState, String?, String)]([
            (
                LocalBranch(name: "main", upstream: "origin/main", tracking: .counts(ahead: 1, behind: 2)),
                HeadState.named("main"), "2 behind, 1 ahead", "Switch branch · origin/main: 2 behind, 1 ahead"
            ),
            (
                LocalBranch(name: "main", upstream: "origin/main", tracking: .counts(ahead: 0, behind: 0)),
                .named("main"), nil, "Switch branch · origin/main: up to date"
            ),
            (
                LocalBranch(name: "main", upstream: "origin/main", tracking: .gone),
                .named("main"), "remote gone", "Switch branch · origin/main: gone"
            ),
            (
                LocalBranch(name: "main", upstream: nil, tracking: nil),
                .named("main"), nil, "Switch branch"
            ),
            // Detached: no branch is current, so its upstream is not the reader's.
            (
                LocalBranch(name: "main", upstream: "origin/main", tracking: .counts(ahead: 1, behind: 2)),
                .detached(sha: String(repeating: "a", count: 40)), nil, "Switch branch"
            ),
        ]))
    func pickerSummaryAndHelpFollowTheUpstream(
        branch: LocalBranch, headState: HeadState, summary: String?, help: String
    ) async throws {
        let (_, state, _, _) = try await settled(branches: [branch], headState: headState)

        #expect(state.branchTrackingSummary == summary)
        #expect(state.branchSwitchHelp == help)
    }

    /// An upstream is set and unset in branch configuration, so a configuration tick
    /// alone must re-read the list and update the face.
    @Test func aConfigurationTickRefreshesTheTracking() async throws {
        let untracked = LocalBranch(name: "main", upstream: nil, tracking: nil)
        let (h, state, client, root) = try await settled(branches: [untracked], headState: .named("main"))
        #expect(state.branchTrackingSummary == nil)

        await client.set(localBranches: [
            LocalBranch(name: "main", upstream: "origin/main", tracking: .counts(ahead: 3, behind: 0))
        ])
        h.tick(root, [.configuration])
        #expect(await eventually { await state.branchTrackingSummary == "3 ahead" })
        #expect(state.branchSwitchHelp == "Switch branch · origin/main: 3 ahead")

        await client.set(localBranches: [untracked])
        h.tick(root, [.configuration])
        #expect(await eventually { await state.branchTrackingSummary == nil })
        #expect(state.branchSwitchHelp == "Switch branch")
    }
}
