import Foundation
import Testing

@testable import DiffViewer

/// Opening the branch picker fetches the remote its ahead/behind counts are read from.
@MainActor
struct WindowStateRemoteTests {
    private let tracked = [localBranch("main", upstream: upstream("origin/main"))]

    /// Adopts a repository and waits for the first paired HEAD + branch read to land.
    @discardableResult
    private func adopt(
        _ h: Harness, _ state: WindowState, branches: [LocalBranch]? = nil, remotes: [String] = ["origin"]
    ) async -> (root: RepositoryRoot, client: StubRepoClient) {
        let repo = h.repo("A", files: [changedFile("a.swift")])
        await repo.client.set(localBranches: branches ?? tracked)
        await repo.client.set(remoteNames: remotes)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.branchReadStatus == .loaded })
        return repo
    }

    /// Lets an already-scheduled task reach its first guard, which it hits without
    /// suspending. Never used to wait for work to finish.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// A watcher tick, so a change to the stub's branches reaches the window.
    private func reread(_ h: Harness, _ repo: (root: RepositoryRoot, client: StubRepoClient)) {
        h.tick(repo.root, [.refs])
    }

    // MARK: Fetching on open

    @Test func openingThePickerFetchesAndRereadsTheBranches() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        let readsBefore = await repo.client.localBranchesCalls
        let at = h.clock

        state.isBranchPickerPresented = true
        #expect(await eventually { await state.fetchStatus == .fetched(remote: "origin", at: at) })
        #expect(await repo.client.fetchCalls == ["origin"])
        #expect(await repo.client.localBranchesCalls > readsBefore, "the counts are read again after the fetch")
    }

    @Test func aSecondOpeningWaitsOutTheCooldown() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        let at = h.clock

        state.isBranchPickerPresented = true
        #expect(await eventually { await state.fetchStatus == .fetched(remote: "origin", at: at) })
        state.isBranchPickerPresented = false

        state.isBranchPickerPresented = true
        // The cooldown is decided after the remotes are read, so that read is the signal
        // that the second attempt ran at all.
        #expect(await eventually { await repo.client.remoteNamesCalls == 2 })
        #expect(await eventually { await state.fetchStatus == .fetched(remote: "origin", at: at) })
        #expect(await repo.client.fetchCalls == ["origin"], "still inside the cooldown")

        state.isBranchPickerPresented = false
        h.clock += WindowState.fetchCooldown + 1
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.fetchCalls == ["origin", "origin"] })
    }

    /// Each remote has its own cooldown, and the footer describes the remote that was
    /// wanted rather than whichever was fetched last.
    @Test func eachRemoteKeepsItsOwnCooldown() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, remotes: ["origin", "fork"])
        let originAt = h.clock

        state.isBranchPickerPresented = true
        #expect(await eventually { await state.fetchStatus == .fetched(remote: "origin", at: originAt) })
        state.isBranchPickerPresented = false

        h.clock += 10
        await repo.client.set(localBranches: [localBranch("main", upstream: upstream("fork/main", remote: "fork"))])
        reread(h, repo)
        #expect(await eventually { await state.currentBranch?.upstream?.remote == "fork" })
        state.isBranchPickerPresented = true
        #expect(await eventually { await state.fetchStatus == .fetched(remote: "fork", at: h.clock) })
        #expect(await repo.client.fetchCalls == ["origin", "fork"])
        state.isBranchPickerPresented = false

        await repo.client.set(localBranches: tracked)
        reread(h, repo)
        #expect(await eventually { await state.currentBranch?.upstream?.remote == "origin" })
        state.isBranchPickerPresented = true
        #expect(await eventually { await state.fetchStatus == .fetched(remote: "origin", at: originAt) })
        #expect(await repo.client.fetchCalls == ["origin", "fork"], "origin is still fresh")
    }

    @Test func openingWithAnUnreadListReadsItFirst() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: [changedFile("a.swift")])
        await repo.client.set(localBranches: [localBranch("main", upstream: upstream("fork/main", remote: "fork"))])
        await repo.client.set(remoteNames: ["origin", "fork"])
        await repo.client.holdLocalBranches(true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(state.branchReadStatus == .unread)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 2 }, "the picker retries the read")
        #expect(await repo.client.fetchCalls.isEmpty)

        await repo.client.holdLocalBranches(false)
        await repo.client.releaseLocalBranches()
        #expect(await eventually { await repo.client.fetchCalls == ["fork"] })
    }

    // MARK: Failures

    @Test func aFailedFetchStartsNoCooldownAndIsNotRetried() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        await repo.client.fail(fetch: true)

        state.isBranchPickerPresented = true
        #expect(await eventually { if case .failed = await state.fetchStatus { true } else { false } })
        guard case let .failed(remote, message) = state.fetchStatus else { return }
        #expect(remote == "origin")
        #expect(!message.isEmpty)
        // The follow-up is decided when the status is published, so a settled status is
        // proof that no second fetch was started.
        #expect(await repo.client.fetchCalls == ["origin"], "a failure of the same remote is not retried")

        state.isBranchPickerPresented = false
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.fetchCalls == ["origin", "origin"] }, "no cooldown was started")
    }

    @Test func aFailedFetchThenAFailedReadRecoversOnTheNextOpening() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        await repo.client.fail(fetch: true)

        state.isBranchPickerPresented = true
        #expect(await eventually { if case .failed = await state.fetchStatus { true } else { false } })
        state.isBranchPickerPresented = false

        await repo.client.fail(localBranches: true)
        reread(h, repo)
        #expect(await eventually { await state.branchReadStatus == .failed })

        await repo.client.fail(localBranches: false)
        await repo.client.fail(fetch: false)
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.fetchCalls == ["origin", "origin"] })
        #expect(state.branchReadStatus == .loaded)
    }

    @Test func aSuccessfulFetchThenAFailedReadRetriesOnlyTheRead() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        let at = h.clock

        state.isBranchPickerPresented = true
        #expect(await eventually { await state.fetchStatus == .fetched(remote: "origin", at: at) })
        state.isBranchPickerPresented = false

        await repo.client.fail(localBranches: true)
        reread(h, repo)
        #expect(await eventually { await state.branchReadStatus == .failed })

        await repo.client.fail(localBranches: false)
        state.isBranchPickerPresented = true
        #expect(await eventually { await state.branchReadStatus == .loaded })
        #expect(await eventually { await state.fetchStatus == .fetched(remote: "origin", at: at) })
        #expect(await repo.client.fetchCalls == ["origin"], "the fetch is still fresh")
    }

    @Test func aFailedRemoteDiscoveryNamesNoRemote() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        await repo.client.fail(remoteNames: true)

        state.isBranchPickerPresented = true
        #expect(await eventually { if case .failed(nil, _) = await state.fetchStatus { true } else { false } })
        #expect(await repo.client.fetchCalls.isEmpty)
    }

    // MARK: Choosing the remote

    @Test func theRemoteIsTheUpstreamThenOriginThenTheOnlyOne() {
        let head = HeadState.named("main")
        let branches = [localBranch("main", upstream: upstream("fork/main", remote: "fork"))]
        #expect(
            WindowState.resolveFetchRemote(headState: head, branches: branches, remotes: ["origin", "fork"]) == "fork")
        // An upstream on a remote git no longer has falls through to the rest.
        #expect(WindowState.resolveFetchRemote(headState: head, branches: branches, remotes: ["origin"]) == "origin")
        #expect(WindowState.resolveFetchRemote(headState: head, branches: branches, remotes: ["other"]) == "other")
        #expect(
            WindowState.resolveFetchRemote(headState: head, branches: [localBranch("main")], remotes: ["a", "b"]) == nil
        )
        #expect(WindowState.resolveFetchRemote(headState: nil, branches: [], remotes: ["upstream"]) == "upstream")
        #expect(WindowState.resolveFetchRemote(headState: nil, branches: [], remotes: []) == nil)
    }

    @Test func noResolvableRemoteFetchesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [localBranch("main")], remotes: ["a", "b"])

        state.isBranchPickerPresented = true
        #expect(await eventually { await state.fetchStatus == .noFetchTarget })
        #expect(await repo.client.fetchCalls.isEmpty)
    }

    // MARK: Dismissal and closing

    @Test func aDismissalBeforeTheTaskRunsFetchesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)

        state.isBranchPickerPresented = true
        state.isBranchPickerPresented = false
        await settle()
        #expect(await repo.client.remoteNamesCalls == 0)
        #expect(state.fetchStatus == .idle)
    }

    @Test func aDismissalDuringDiscoveryReleasesTheReservation() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        await repo.client.holdRemoteNames(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldRemoteNamesCount == 1 })
        state.isBranchPickerPresented = false
        await repo.client.holdRemoteNames(false)
        await repo.client.releaseRemoteNames()

        #expect(await eventually { await state.fetchStatus == .idle })
        #expect(await repo.client.fetchCalls.isEmpty)
    }

    /// The reservation is the admission guard: a second opening while one attempt is
    /// still resolving does not start another.
    @Test func aSecondOpeningDuringDiscoveryStartsNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        await repo.client.holdRemoteNames(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldRemoteNamesCount == 1 })
        state.isBranchPickerPresented = false
        state.isBranchPickerPresented = true

        await repo.client.holdRemoteNames(false)
        await repo.client.releaseRemoteNames()
        #expect(await eventually { await state.fetchStatus == .fetched(remote: "origin", at: h.clock) })
        #expect(await repo.client.remoteNamesCalls == 1, "the second opening started nothing")
        #expect(await repo.client.fetchCalls == ["origin"])
    }

    @Test func theFetchStaysReservedUntilTheCountsCatchUp() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        await repo.client.holdLocalBranches(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(await repo.client.fetchCalls == ["origin"])
        #expect(state.fetchStatus == .fetching(remote: "origin"))

        await repo.client.holdLocalBranches(false)
        await repo.client.releaseLocalBranches()
        #expect(await eventually { if case .fetched = await state.fetchStatus { true } else { false } })
    }

    @Test func aDismissalDuringTheFetchStillRecordsIt() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        let at = h.clock
        await repo.client.holdFetch(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        let readsBefore = await repo.client.localBranchesCalls
        state.isBranchPickerPresented = false
        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()

        #expect(await eventually { await state.fetchStatus == .fetched(remote: "origin", at: at) })
        #expect(await repo.client.localBranchesCalls > readsBefore, "the counts still catch up")

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.remoteNamesCalls == 2 })
        #expect(await repo.client.fetchCalls == ["origin"], "the cooldown was recorded")
    }

    // MARK: Following a changed remote

    @Test func aRemoteThatChangedDuringTheFetchIsFetchedOnce() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, remotes: ["origin", "fork"])
        await repo.client.holdFetch(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        // The branch now tracks another remote, as a switch during the fetch would leave it.
        await repo.client.set(localBranches: [localBranch("main", upstream: upstream("fork/main", remote: "fork"))])
        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()

        #expect(await eventually { await state.fetchStatus == .fetched(remote: "fork", at: h.clock) })
        #expect(await repo.client.fetchCalls == ["origin", "fork"], "one follow-up, then the cycle ends")
    }

    @Test func aDismissalDuringTheFetchStopsTheFollowUp() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, remotes: ["origin", "fork"])
        await repo.client.holdFetch(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        await repo.client.set(localBranches: [localBranch("main", upstream: upstream("fork/main", remote: "fork"))])
        state.isBranchPickerPresented = false
        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()

        #expect(await eventually { if case .fetched = await state.fetchStatus { true } else { false } })
        #expect(await repo.client.fetchCalls == ["origin"], "nothing follows a dismissed picker")
    }

    /// A failing fetch is still followed up: the branch may have moved to another remote
    /// while it ran, and that remote's counts are what the picker is about to show.
    @Test func aFailedFetchStillFollowsAChangedRemote() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, remotes: ["origin", "fork"])
        await repo.client.holdFetch(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        await repo.client.set(localBranches: [localBranch("main", upstream: upstream("fork/main", remote: "fork"))])
        await repo.client.fail(fetch: true)
        await repo.client.releaseFetch()

        // The follow-up is held in turn, which is proof it started.
        #expect(await eventually { await repo.client.fetchCalls == ["origin", "fork"] })
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        await repo.client.fail(fetch: false)
        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()

        #expect(await eventually { await state.fetchStatus == .fetched(remote: "fork", at: h.clock) })
        #expect(await repo.client.fetchCalls == ["origin", "fork"], "exactly one follow-up")
        #expect(state.session?.lastSuccessfulFetchAtByRemote["origin"] == nil, "a failure starts no cooldown")
    }

    /// The counts have to come from a read that published: one superseded by a watcher
    /// tick describes a moment the fetch cannot vouch for, so the reservation waits for
    /// the read that replaced it rather than starting another.
    @Test func aSupersededPostFetchReadKeepsTheReservation() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, remotes: ["origin", "fork"])
        await repo.client.holdLocalBranches(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        // A watcher tick supersedes the fetch's own read while it is held.
        await repo.client.set(localBranches: [localBranch("main", upstream: upstream("fork/main", remote: "fork"))])
        reread(h, repo)
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 2 })

        await repo.client.holdLocalBranches(false)
        await repo.client.releaseFirstLocalBranches()  // the fetch's own read, now superseded
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(state.fetchStatus == .fetching(remote: "origin"), "the reservation waits for the replacement")
        #expect(await repo.client.localBranchesCalls == 3, "no third read is started")

        await repo.client.releaseLocalBranches()
        // The read that lands carries the new upstream, and the follow-up acts on it.
        #expect(await eventually { await repo.client.fetchCalls == ["origin", "fork"] })
        #expect(await eventually { await state.fetchStatus == .fetched(remote: "fork", at: h.clock) })
    }

    /// The same wait before the fetch: an opening that has to read the branches first
    /// takes the answer of whichever read publishes.
    @Test func aSupersededPreFetchReadWaitsForTheOneThatPublishes() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: [changedFile("a.swift")])
        await repo.client.set(localBranches: tracked)
        await repo.client.set(remoteNames: ["origin"])
        await repo.client.holdLocalBranches(true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(state.branchReadStatus == .unread)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 2 })
        reread(h, repo)
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 3 })

        await repo.client.holdLocalBranches(false)
        await repo.client.releaseFirstLocalBranches()  // adoption's read, superseded
        await repo.client.releaseFirstLocalBranches()  // the picker's read, superseded
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(state.fetchStatus == .fetching(remote: nil), "nothing is fetched until a read publishes")
        #expect(await repo.client.fetchCalls.isEmpty)

        await repo.client.releaseLocalBranches()
        #expect(await eventually { await repo.client.fetchCalls == ["origin"] })
    }

    /// The follow-up tries each remote once per opening, so two branches pointing at each
    /// other cannot keep it going.
    @Test func aRemoteAlreadyTriedIsNotFetchedAgain() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, remotes: ["origin", "fork"])
        let fork = [localBranch("main", upstream: upstream("fork/main", remote: "fork"))]
        await repo.client.holdFetch(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        await repo.client.set(localBranches: fork)
        await repo.client.fail(fetch: true)
        await repo.client.releaseFetch()

        // origin failed and the branch now tracks fork, so fork is fetched next.
        #expect(await eventually { await repo.client.fetchCalls == ["origin", "fork"] })
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        // And back again while fork's fetch runs: origin has no cooldown, only a turn spent.
        await repo.client.set(localBranches: tracked)
        await repo.client.fail(fetch: false)
        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()

        #expect(await eventually { await state.fetchStatus == .fetched(remote: "fork", at: h.clock) })
        #expect(await repo.client.fetchCalls == ["origin", "fork"], "origin had its turn")
    }

    @Test func closingDuringTheFetchPublishesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        await repo.client.holdFetch(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        state.close()
        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()
        await settle()
        #expect(state.fetchStatus == .fetching(remote: "origin"), "a closed window publishes nothing")
        #expect(await repo.client.fetchCalls == ["origin"])
    }
}
