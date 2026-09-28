import Testing

@testable import DiffViewer

/// Which commits the picker marks as not pushed, and when the reads behind them run.
@MainActor
struct WindowStateUnpushedCommitsTests {
    private let upstreamRef = "refs/remotes/origin/main"
    private let unpushed: Set<String> = [objectID("u1"), objectID("u2")]

    private func main(tip: String = objectID("tip1"), tracking: BranchUpstream? = nil) -> LocalBranch {
        let ahead = upstream("origin/main", tracking: .counts(ahead: 2, behind: 0))
        return localBranch("main", upstream: tracking ?? ahead, tipSha: tip)
    }

    /// A window on `main`, two ahead of `origin/main` unless `branch` says otherwise,
    /// waited on past its first branch read.
    private func settled(branch: LocalBranch? = nil) async -> (state: WindowState, client: StubRepoClient) {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: [changedFile("a.swift")])
        await repo.client.set(localBranches: [branch ?? main()])
        await repo.client.set(commitSha: objectID("up1"), for: upstreamRef)
        await repo.client.set(unpushed: unpushed)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.branchReadStatus == .loaded })
        return (state, repo.client)
    }

    @Test func aCacheHitResolvesTheUpstreamButSkipsTheRevList() async {
        let (state, client) = await settled()
        #expect(state.unpushedCommitShas == unpushed)
        #expect(await client.unpushedCalls.map(\.tip) == [objectID("tip1")])
        #expect(await client.unpushedCalls.map(\.upstreamTip) == [objectID("up1")])

        await state.refresh()
        #expect(await client.commitShaCalls == [upstreamRef, upstreamRef])
        #expect(await client.unpushedCalls.count == 1)
        #expect(state.unpushedCommitShas == unpushed)
    }

    @Test func aMovedTipOrUpstreamReadsAgain() async {
        let (state, client) = await settled()

        await client.set(localBranches: [main(tip: objectID("tip2"))])
        await client.set(unpushed: [objectID("u3")])
        await state.refresh()
        #expect(state.unpushedCommitShas == [objectID("u3")])
        #expect(await client.unpushedCalls.last?.tip == objectID("tip2"))

        await client.set(commitSha: objectID("up2"), for: upstreamRef)
        await client.set(unpushed: [objectID("u4")])
        await state.refresh()
        #expect(state.unpushedCommitShas == [objectID("u4")])
        #expect(await client.unpushedCalls.last?.upstreamTip == objectID("up2"))
        #expect(await client.unpushedCalls.count == 3)
    }

    @Test func anUnresolvableUpstreamEmptiesTheSet() async {
        let (state, client) = await settled()
        #expect(!state.unpushedCommitShas.isEmpty)

        await client.set(commitSha: nil, for: upstreamRef)
        await state.refresh()
        #expect(state.unpushedCommitShas.isEmpty)
        #expect(await client.unpushedCalls.count == 1, "no rev-list without an upstream tip")
    }

    /// Being ahead of a local branch, or of nothing, says nothing about the remote.
    @Test(arguments: [
        upstream("base", remote: ".", localRef: "refs/heads/base", tracking: .counts(ahead: 1, behind: 0)),
        upstream("origin/main", tracking: .counts(ahead: 0, behind: 3)),
        upstream("origin/main", tracking: .gone),
    ])
    func noReadsUnlessAheadOfARemoteTrackingUpstream(tracking: BranchUpstream) async {
        let (state, client) = await settled(branch: main(tracking: tracking))
        #expect(state.unpushedCommitShas.isEmpty)
        #expect(await client.commitShaCalls.isEmpty)
        #expect(await client.unpushedCalls.isEmpty)
    }

    /// A failed read cannot leave the last branch's commits marked, cached or not.
    @Test func aFailedReadEmptiesTheSet() async {
        let (state, client) = await settled()

        await client.set(localBranches: [main(tip: objectID("tip2"))])
        await client.fail(unpushed: true)
        await state.refresh()
        #expect(state.unpushedCommitShas.isEmpty)
        #expect(state.branchReadStatus == .loaded, "the branch read itself still publishes")

        await client.fail(unpushed: false)
        await client.set(localBranches: [main()])
        await client.fail(commitSha: true)
        await state.refresh()
        #expect(state.unpushedCommitShas.isEmpty)

        await client.fail(commitSha: false)
        await state.refresh()
        #expect(state.unpushedCommitShas == unpushed, "the first tip's answer is still cached")
        #expect(await client.unpushedCalls.count == 2)
    }

    /// The branches stay on show after a failed branch read, but their marks do not: a
    /// push may be what the read missed.
    @Test func aFailedBranchReadEmptiesTheSet() async {
        let (state, client) = await settled()
        #expect(state.unpushedCommitShas == unpushed)

        await client.fail(localBranches: true)
        await state.refresh()
        #expect(state.branchReadStatus == .failed)
        #expect(state.unpushedCommitShas.isEmpty)
    }
}
