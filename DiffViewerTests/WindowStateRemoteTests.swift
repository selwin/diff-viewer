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

    // MARK: Other remotes

    /// `main` tracks origin and `feature` tracks fork.
    private let twoRemotes = [
        localBranch("main", upstream: upstream("origin/main")),
        localBranch("feature", upstream: upstream("fork/feature", remote: "fork")),
    ]

    /// True once the primary has published `status` and no fetch is left in flight. The
    /// other remotes start in the same turn as that status, so both reads are made
    /// together: a remote started by mistake cannot slip between them.
    private func settled(_ state: WindowState, at status: FetchStatus) async -> Bool {
        await eventually { @MainActor in state.fetchStatus == status && state.fetchingRemotes.isEmpty }
    }

    @Test func everyRemoteAListedBranchTracksIsFetched() async {
        let h = Harness()
        let state = h.makeState()
        let branches = twoRemotes + [localBranch("old", upstream: upstream("gone/old", remote: "gone"))]
        let repo = await adopt(h, state, branches: branches, remotes: ["origin", "fork"])

        state.isBranchPickerPresented = true
        #expect(await settled(state, at: .fetched(remote: "origin", at: h.clock)))
        #expect(await repo.client.fetchCalls == ["origin", "fork"], "the header's remote first, never a missing one")
        #expect(state.secondaryFetchFailures.isEmpty)
    }

    @Test func anotherRemoteWithinItsCooldownIsNotFetchedAgain() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: twoRemotes, remotes: ["origin", "fork"])
        await repo.client.fail(fetch: true, remote: "origin")

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.fetchCalls == ["origin", "fork"] })
        #expect(await eventually { await state.fetchingRemotes.isEmpty })
        state.isBranchPickerPresented = false

        // origin failed, so it has no cooldown and is fetched again.
        await repo.client.fail(fetch: false, remote: "origin")
        h.clock += 10
        state.isBranchPickerPresented = true
        #expect(await settled(state, at: .fetched(remote: "origin", at: h.clock)))
        #expect(await repo.client.fetchCalls == ["origin", "fork", "origin"], "fork is still fresh")
    }

    @Test func reopeningJoinsAnotherRemotesFetchInsteadOfRepeatingIt() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: twoRemotes, remotes: ["origin", "fork"])
        await repo.client.holdFetch(true, remote: "fork")

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        #expect(state.fetchStatus == .fetched(remote: "origin", at: h.clock), "a slow remote holds back only itself")
        #expect(state.fetchingRemotes == ["fork"])
        state.isBranchPickerPresented = false

        // origin's cooldown has run out, so its fetch shows the reopening got past it.
        h.clock += WindowState.fetchCooldown + 1
        state.isBranchPickerPresented = true
        #expect(await eventually { await state.fetchStatus == .fetched(remote: "origin", at: h.clock) })
        await repo.client.holdFetch(false, remote: "fork")
        await repo.client.releaseFetch()
        #expect(await eventually { await state.fetchingRemotes.isEmpty })
        #expect(await repo.client.fetchCalls == ["origin", "fork", "origin"], "fork was fetched once")
    }

    @Test func anotherRemotesFailureIsReportedUntilItSucceeds() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: twoRemotes, remotes: ["origin", "fork"])
        await repo.client.fail(fetch: true, remote: "fork")

        state.isBranchPickerPresented = true
        #expect(await eventually { await state.secondaryFetchFailures["fork"] != nil })
        #expect(state.fetchStatus == .fetched(remote: "origin", at: h.clock))
        #expect(state.errorMessage == nil, "footer news, never an alert")
        state.isBranchPickerPresented = false

        await repo.client.fail(fetch: false, remote: "fork")
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.fetchCalls == ["origin", "fork", "fork"] }, "no cooldown")
        #expect(await eventually { await state.fetchingRemotes.isEmpty })
        #expect(state.secondaryFetchFailures.isEmpty)
    }
}

/// Pulling and pushing the current branch from the branch picker.
@MainActor
struct WindowStateSyncTests {
    /// A branch tracking `origin/main`, `behind` commits behind and `ahead` ahead.
    private func main(ahead: Int = 0, behind: Int = 2, remote: String = "origin") -> [LocalBranch] {
        [
            localBranch(
                "main",
                upstream: upstream(
                    "\(remote)/main", remote: remote, tracking: .counts(ahead: ahead, behind: behind)))
        ]
    }

    @discardableResult
    private func adopt(_ h: Harness, _ state: WindowState, branches: [LocalBranch]) async -> (
        root: RepositoryRoot, client: StubRepoClient
    ) {
        let repo = h.repo("A", files: [changedFile("a.swift")])
        await repo.client.set(localBranches: branches)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.branchReadStatus == .loaded })
        return repo
    }

    // MARK: Admission

    @Test func aPullIsRefusedWhileTheFetchRuns() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.holdFetch(true)
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })

        await state.pull()
        #expect(await repo.client.pullCalls == 0)
        #expect(state.activeSyncOperation == nil)

        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()
    }

    @Test func aPullIsRefusedWhileTheRemotesAreDiscovered() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.holdRemoteNames(true)
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldRemoteNamesCount == 1 })

        await state.pull()
        #expect(await repo.client.pullCalls == 0, "discovery may yet resolve to origin")
        #expect(state.activeSyncOperation == nil)

        await repo.client.holdRemoteNames(false)
        await repo.client.releaseRemoteNames()
    }

    @Test func aPushIsAdmittedWhileAnotherRemoteIsFetched() async {
        let h = Harness()
        let state = h.makeState()
        let feature = localBranch("feature", upstream: upstream("fork/feature", remote: "fork"))
        let repo = await adopt(h, state, branches: main(ahead: 1, behind: 0) + [feature])
        await repo.client.set(remoteNames: ["origin", "fork"])
        await repo.client.holdFetch(true, remote: "fork")
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        #expect(state.fetchingRemotes == ["fork"])

        await state.push()
        #expect(await repo.client.pushCalls.map(\.remote) == ["origin"])

        await repo.client.holdFetch(false, remote: "fork")
        await repo.client.releaseFetch()
    }

    @Test func aPullIsRefusedWhileABranchSwitchRuns() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main() + [localBranch("feature")])
        await repo.client.holdSwitchBranch(true)
        let switching = Task { await state.switchBranch(to: "feature") }
        #expect(await eventually { await repo.client.heldSwitchBranchCount == 1 })

        await state.pull()
        #expect(await repo.client.pullCalls == 0)
        #expect(state.activeSyncOperation == nil)

        await repo.client.holdSwitchBranch(false)
        await repo.client.releaseSwitchBranch()
        await switching.value
    }

    /// The pull is a repository write like any other: it waits its turn behind one that
    /// is already running, rather than racing it for `index.lock`.
    @Test func aPullWaitsBehindAFileActionOnTheWriteChain() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.holdActions(true)

        let action = Task { await state.perform(.stage, on: [changedFile("a.swift")]) }
        #expect(await eventually { await repo.client.heldActionCount == 1 })
        let pulling = Task { await state.pull() }
        #expect(await eventually { await state.activeSyncOperation == .pull }, "reserved while it queues")
        #expect(await repo.client.pullCalls == 0, "the write ahead of it still holds the repository")

        await repo.client.holdActions(false)
        await repo.client.releaseActions()
        await action.value
        await pulling.value
        #expect(await repo.client.pullCalls == 1)
        #expect(state.activeSyncOperation == nil)
    }

    // MARK: Revalidation

    @Test func aPullSkipsWhenTheUpstreamMovedToAnotherRemote() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        // What the repository says by the time the pull takes its turn.
        await repo.client.set(localBranches: main(remote: "fork"))

        await state.pull()
        #expect(await repo.client.pullCalls == 0)
        #expect(state.errorMessage == "Branch or upstream changed before the pull could start")
        #expect(state.activeSyncOperation == nil)
        #expect(state.currentBranch?.upstream?.remote == "fork", "the branches were re-read")
    }

    @Test func aPullSkipsWhenHeadMovedAway() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.set(headState: .detached(sha: objectID("x")))

        await state.pull()
        #expect(await repo.client.pullCalls == 0)
        #expect(state.errorMessage == "Branch or upstream changed before the pull could start")
    }

    @Test func aPushSkipsWhenTheUpstreamWasRemoved() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main(ahead: 1, behind: 0))
        await repo.client.set(localBranches: [localBranch("main")])

        await state.push()
        #expect(await repo.client.pushCalls.isEmpty)
        #expect(state.errorMessage == "Branch or upstream changed before the push could start")
    }

    @Test func aPullRunsWhenOnlyTheCountsMoved() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main(behind: 2))
        await repo.client.set(localBranches: main(behind: 3))

        await state.pull()
        #expect(await repo.client.pullCalls == 1)
        #expect(state.errorMessage == nil)
    }

    /// Someone else pulled first: the refreshed header says there is nothing to take, so
    /// an alert would only repeat it.
    @Test func aPullSkipsSilentlyWhenNothingIsBehind() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main(behind: 2))
        await repo.client.set(localBranches: main(behind: 0))

        await state.pull()
        #expect(await repo.client.pullCalls == 0)
        #expect(state.errorMessage == nil)
        #expect(state.currentBranch?.upstream?.tracking == .counts(ahead: 0, behind: 0), "the branches were re-read")
        #expect(state.activeSyncOperation == nil)
    }

    @Test func aThrowingRevalidationReleasesTheReservation() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.fail(headState: true)

        await state.pull()
        #expect(await repo.client.pullCalls == 0)
        #expect(state.errorMessage != nil)
        #expect(state.activeSyncOperation == nil)
    }

    // MARK: Running

    /// A failed pull can leave conflicts, a merge in progress, or an autostash put back,
    /// so the working tree is re-read either way and the failure is reported after it.
    @Test func aFailedPullStillRefreshesAndReports() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.fail(pull: true)

        await state.pull()
        #expect(await repo.client.pullCalls == 1)
        #expect(h.published.contains { $0.cause == .pull })
        #expect(state.errorMessage != nil)
        #expect(state.activeSyncOperation == nil)
    }

    @Test func aPushSendsTheTrackedRefAndRereadsTheCountsOnly() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main(ahead: 2, behind: 0))
        let publishedBefore = h.published.count
        let readsBefore = await repo.client.localBranchesCalls

        await state.push()
        let pushes = await repo.client.pushCalls
        #expect(pushes.map(\.branch) == ["main"])
        #expect(pushes.map(\.remote) == ["origin"])
        #expect(pushes.map(\.remoteRef) == ["refs/heads/main"])
        #expect(h.published.count == publishedBefore, "a push changes no file")
        #expect(await repo.client.localBranchesCalls > readsBefore, "the counts are re-read")
        #expect(state.activeSyncOperation == nil)
        #expect(state.errorMessage == nil)
    }

    /// The buttons keep their running state until the counts they will be drawn from
    /// have landed, even when a watcher tick takes the operation's own read.
    @Test func aSupersededPostPullReadKeepsTheRunningState() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())

        await repo.client.holdLocalBranches(true)
        let pulling = Task { await state.pull() }
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 }, "the revalidation read")
        await repo.client.releaseFirstLocalBranches()
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 }, "the post-pull read")
        let readsBefore = await repo.client.localBranchesCalls

        // A watcher tick supersedes the post-pull read while it is held.
        h.tick(repo.root, [.refs])
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 2 })
        await repo.client.releaseFirstLocalBranches()
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(state.activeSyncOperation == .pull, "still running until a read publishes")
        #expect(await repo.client.localBranchesCalls == readsBefore + 1, "no extra read is started")

        await repo.client.holdLocalBranches(false)
        await repo.client.releaseLocalBranches()
        await pulling.value
        #expect(state.activeSyncOperation == nil)
        #expect(await repo.client.pullCalls == 1)
    }

    /// The picker's fetch and a sync move the same counts, so one waits for the other.
    @Test func noFetchStartsWhileASyncIsActive() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.holdPull(true)

        let pulling = Task { await state.pull() }
        #expect(await eventually { await repo.client.heldPullCount == 1 })
        state.isBranchPickerPresented = true
        await state.fetchForBranchPicker()
        #expect(await repo.client.remoteNamesCalls == 0)
        #expect(await repo.client.fetchCalls.isEmpty)
        #expect(state.fetchStatus == .idle)

        await repo.client.holdPull(false)
        await repo.client.releasePull()
        await pulling.value
    }

    @Test func closingDuringAQueuedPullRunsNoPull() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.holdActions(true)

        let action = Task { await state.perform(.stage, on: [changedFile("a.swift")]) }
        #expect(await eventually { await repo.client.heldActionCount == 1 })
        let pulling = Task { await state.pull() }
        #expect(await eventually { await state.activeSyncOperation == .pull })
        let publishedBefore = h.published.count
        state.close()

        await repo.client.holdActions(false)
        await repo.client.releaseActions()
        await action.value
        await pulling.value
        #expect(await repo.client.pullCalls == 0, "a closed window starts no write")
        #expect(h.published.count == publishedBefore)
    }

    @Test func closingDuringAPullPublishesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.holdPull(true)

        let pulling = Task { await state.pull() }
        #expect(await eventually { await repo.client.heldPullCount == 1 })
        let publishedBefore = h.published.count
        state.close()
        await repo.client.holdPull(false)
        await repo.client.releasePull()
        await pulling.value

        #expect(h.published.count == publishedBefore, "a closed window publishes nothing")
        #expect(state.errorMessage == nil)
    }
}
