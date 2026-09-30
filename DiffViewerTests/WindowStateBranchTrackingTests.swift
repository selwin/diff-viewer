import Testing

@testable import DiffViewer

/// What the branch picker's help and sync presentation say about the current branch's upstream.
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
        arguments: [(LocalBranch, HeadState, String)]([
            (
                localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 1, behind: 2))),
                HeadState.named("main"), "Switch branch · origin/main: 1 ahead · 2 behind"
            ),
            (
                localBranch("main", upstream: upstream("origin/main")),
                .named("main"), "Switch branch · origin/main: up to date"
            ),
            (
                localBranch("main", upstream: upstream("origin/main", tracking: .gone)),
                .named("main"), "Switch branch · origin/main: gone"
            ),
            (
                localBranch("main"),
                .named("main"), "Switch branch"
            ),
            // Detached: no branch is current, so its upstream is not the reader's.
            (
                localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 1, behind: 2))),
                .detached(sha: String(repeating: "a", count: 40)), "Switch branch"
            ),
        ]))
    func pickerHelpFollowsTheUpstream(branch: LocalBranch, headState: HeadState, help: String) async throws {
        let (_, state, _, _) = try await settled(branches: [branch], headState: headState)

        #expect(state.branchSwitchHelp == help)
    }

    /// An upstream is set and unset in branch configuration, so a configuration tick
    /// alone must re-read the list and update the title bar.
    @Test func aConfigurationTickRefreshesTheTracking() async throws {
        let untracked = localBranch("main")
        let (h, state, client, root) = try await settled(branches: [untracked], headState: .named("main"))
        #expect(state.currentBranchSync?.pushCount == nil)

        await client.set(localBranches: [
            localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 3, behind: 0)))
        ])
        h.tick(root, [.configuration])
        #expect(await eventually { await state.branchSwitchHelp == "Switch branch · origin/main: 3 ahead" })
        #expect(state.currentBranchSync?.pushCount == 3)

        await client.set(localBranches: [untracked])
        h.tick(root, [.configuration])
        #expect(await eventually { await state.branchSwitchHelp == "Switch branch" })
        #expect(state.currentBranchSync?.pushCount == nil)
    }
}
