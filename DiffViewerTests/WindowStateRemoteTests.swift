import Foundation
import Testing

@testable import DiffViewer

/// Fetch rounds: opening the branch picker, and its Fetch, update every remote the counts
/// are read from.
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

    /// True once no round is running and the last one ended as `round`. Both are published
    /// in one turn, so one read sees them together.
    private func finished(_ state: WindowState, as round: FetchRound) async -> Bool {
        await eventually { @MainActor in state.fetchStatus == .idle && state.lastFetchRound == round }
    }

    /// Opens the picker and waits for the round it starts to publish.
    private func openAndFinish(_ state: WindowState, as round: FetchRound) async {
        state.isBranchPickerPresented = true
        #expect(await finished(state, as: round))
    }

    /// A round in which every one of `remotes` was fetched at `at`.
    private func fetched(_ remotes: [String], at: Date) -> FetchRound {
        FetchRound(outcomes: Dictionary(uniqueKeysWithValues: remotes.map { ($0, .fetched(at: at)) }))
    }

    nonisolated private static func isFailure(_ outcome: FetchRound.Outcome?) -> Bool {
        if case .failed = outcome { true } else { false }
    }

    // MARK: Fetching on open

    @Test func openingThePickerFetchesAndRereadsTheBranches() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        let readsBefore = await repo.client.localBranchesCalls

        await openAndFinish(state, as: FetchRound(outcomes: ["origin": .fetched(at: h.clock)]))
        #expect(await repo.client.fetchCalls == ["origin"])
        #expect(await repo.client.localBranchesCalls > readsBefore, "the counts are read again after the fetch")
    }

    @Test func openingFetchesEveryRemoteTrackedOrNot() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, remotes: ["origin", "fork", "upstream"])

        await openAndFinish(state, as: fetched(["origin", "fork", "upstream"], at: h.clock))
        #expect(await repo.client.fetchCalls.sorted() == ["fork", "origin", "upstream"])
        #expect(state.remotes == ["origin", "fork", "upstream"])
    }

    @Test func aSecondOpeningWaitsOutTheCooldown() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        let at = h.clock

        await openAndFinish(state, as: FetchRound(outcomes: ["origin": .fetched(at: at)]))
        state.isBranchPickerPresented = false

        state.isBranchPickerPresented = true
        // The cooldown is decided after the remotes are read, so that read is the signal
        // that the second round ran at all.
        #expect(await eventually { await repo.client.remoteNamesCalls == 2 })
        #expect(await finished(state, as: FetchRound(outcomes: ["origin": .fetched(at: at)])))
        #expect(await repo.client.fetchCalls == ["origin"], "still inside the cooldown")

        state.isBranchPickerPresented = false
        h.clock += WindowState.fetchCooldown + 1
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.fetchCalls == ["origin", "origin"] })
    }

    /// A cooldown skip implies an earlier success, so the round carries that time rather
    /// than leaving the remote out.
    @Test func aRemoteSkippedByTheCooldownCarriesItsTimeIntoTheRound() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        let originAt = h.clock
        await openAndFinish(state, as: FetchRound(outcomes: ["origin": .fetched(at: originAt)]))
        state.isBranchPickerPresented = false

        await repo.client.set(remoteNames: ["origin", "fork"])
        h.clock += 10
        await openAndFinish(
            state, as: FetchRound(outcomes: ["origin": .fetched(at: originAt), "fork": .fetched(at: h.clock)]))
        #expect(await repo.client.fetchCalls == ["origin", "fork"], "origin is still fresh")
    }

    // MARK: Fetching by hand

    @Test func aManualRoundCoversEveryRemoteSkipsTheCooldownAndReadsOnce() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, remotes: ["origin", "fork"])
        await openAndFinish(state, as: fetched(["origin", "fork"], at: h.clock))

        h.clock += 10
        let localReads = await repo.client.localBranchesCalls
        let remoteReads = await repo.client.remoteBranchesCalls
        await state.fetchAllRemotes()
        #expect(await repo.client.fetchCalls.sorted() == ["fork", "fork", "origin", "origin"])
        #expect(state.lastFetchRound == fetched(["origin", "fork"], at: h.clock))
        #expect(await repo.client.localBranchesCalls == localReads + 1, "one branch read for the whole round")
        #expect(await repo.client.remoteBranchesCalls == remoteReads + 2, "the refs before, and the read after")
    }

    /// One round per session: the opening's round and ⌘R's share it, and each remote is
    /// fetched once.
    @Test func openingThenFetchingRightAwayRunsOneRound() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, remotes: ["origin", "fork"])
        await repo.client.holdFetch(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 2 })
        let opening = Task { await state.fetchForBranchPicker() }
        let manual = Task { await state.fetchAllRemotes() }
        await settle()
        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()

        let expected = fetched(["origin", "fork"], at: h.clock)
        await opening.value
        #expect(state.lastFetchRound == expected)
        await manual.value
        #expect(state.lastFetchRound == expected)
        #expect(await repo.client.fetchCalls.sorted() == ["fork", "origin"])
        #expect(await repo.client.remoteNamesCalls == 1)
    }

    /// ⌘R right after opening joins the opening's round before it applies the cooldown,
    /// so that one round fetches every remote.
    @Test func fetchingBeforeTheOpeningAppliesTheCooldownUpgradesItsRound() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, remotes: ["origin", "fork"])
        await openAndFinish(state, as: fetched(["origin", "fork"], at: h.clock))
        state.isBranchPickerPresented = false

        h.clock += 10
        await repo.client.holdRemoteNames(true)
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldRemoteNamesCount == 1 })
        let manual = Task { await state.fetchAllRemotes() }
        await settle()
        await repo.client.holdRemoteNames(false)
        await repo.client.releaseRemoteNames()

        await manual.value
        #expect(state.lastFetchRound == fetched(["origin", "fork"], at: h.clock))
        #expect(await repo.client.fetchCalls.sorted() == ["fork", "fork", "origin", "origin"])
        #expect(await repo.client.remoteNamesCalls == 2, "one round, not a second")
    }

    /// Once the opening's round has skipped a remote for its cooldown, ⌘R runs a round of
    /// its own after it, and a second ⌘R meanwhile shares that round.
    @Test func fetchingAfterTheCooldownSkippedARemoteRunsOneFollowUpRound() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        let originAt = h.clock
        await openAndFinish(state, as: fetched(["origin"], at: originAt))
        state.isBranchPickerPresented = false

        await repo.client.set(remoteNames: ["origin", "fork"])
        h.clock += 10
        await repo.client.holdFetch(true, remote: "fork")
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        #expect(await repo.client.fetchCalls == ["origin", "fork"], "origin skipped for its cooldown")

        let first = Task { await state.fetchAllRemotes() }
        let second = Task { await state.fetchAllRemotes() }
        await settle()
        await repo.client.holdFetch(false, remote: "fork")
        await repo.client.releaseFetch()

        await first.value
        await second.value
        #expect(state.lastFetchRound == fetched(["origin", "fork"], at: h.clock))
        #expect(await repo.client.fetchCalls.sorted() == ["fork", "fork", "origin", "origin"])
        #expect(await repo.client.remoteNamesCalls == 3, "the first opening, the second, and one follow-up")
    }

    // MARK: Holding the counts

    /// A remote whose fetch has finished stays held until the round's branch read
    /// publishes, so a pull can't act on counts from before the round.
    @Test func remotesStayHeldUntilTheRoundsReadPublishes() async {
        let h = Harness()
        let state = h.makeState()
        let behind = [
            localBranch("main", upstream: upstream("origin/main", tracking: .counts(ahead: 0, behind: 2)))
        ]
        let repo = await adopt(h, state, branches: behind, remotes: ["origin", "fork"])
        await repo.client.holdFetch(true, remote: "fork")

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        #expect(await eventually { await state.session?.lastSuccessfulFetchAtByRemote["origin"] != nil })
        #expect(state.fetchingRemotes == ["origin", "fork"], "origin's fetch is done, the round's read is not")

        await repo.client.holdLocalBranches(true)
        await repo.client.holdFetch(false, remote: "fork")
        await repo.client.releaseFetch()
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(state.fetchingRemotes == ["origin", "fork"])
        #expect(state.fetchStatus == .fetching)
        await state.pull(branch: "main")
        #expect(await repo.client.pullCalls == 0)

        await repo.client.holdLocalBranches(false)
        await repo.client.releaseLocalBranches()
        #expect(await eventually { await state.fetchingRemotes.isEmpty })
        #expect(state.lastFetchRound?.outcomes.count == 2)
    }

    /// The counts have to come from a read that published: one superseded by a watcher
    /// tick describes a moment the round cannot vouch for, so the round waits for the read
    /// that replaced it rather than starting another, and that read publishes it.
    @Test func aSupersededRoundReadHandsTheRoundToItsReplacement() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        let main = remoteBranch("main")
        let feature = remoteBranch("feature")
        await repo.client.set(remoteBranches: [main])
        await repo.client.holdLocalBranches(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        await repo.client.set(remoteBranches: [main, feature])
        reread(h, repo)
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 2 })

        await repo.client.holdLocalBranches(false)
        await repo.client.releaseFirstLocalBranches()  // the round's own read, now superseded
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(state.fetchingRemotes == ["origin"], "the round waits for the replacement")
        #expect(state.lastFetchRound == nil)
        #expect(await repo.client.localBranchesCalls == 3, "no third read is started")

        await repo.client.releaseLocalBranches()
        #expect(await finished(state, as: FetchRound(outcomes: ["origin": .fetched(at: h.clock)])))
        #expect(state.fetchingRemotes.isEmpty)
        #expect(state.newRemoteBranches == [feature.ref])
    }

    @Test func aFailedRoundReadReleasesTheRemotesAndKeepsTheOldBranches() async {
        let h = Harness()
        let state = h.makeState()
        let main = remoteBranch("main")
        let repo = h.repo("A", files: [changedFile("a.swift")])
        await repo.client.set(localBranches: tracked)
        await repo.client.set(remoteBranches: [main])
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.branchReadStatus == .loaded })
        await repo.client.holdFetch(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        await repo.client.set(remoteBranches: [main, remoteBranch("feature")])
        await repo.client.set(localBranches: [localBranch("feature")])
        await repo.client.fail(localBranches: true)
        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()

        #expect(await finished(state, as: FetchRound(outcomes: ["origin": .fetched(at: h.clock)])))
        #expect(state.fetchingRemotes.isEmpty)
        #expect(state.branchReadStatus == .failed)
        #expect(state.branches == tracked)
        #expect(state.remoteBranches == [main])
        #expect(state.newRemoteBranches.isEmpty, "nothing read, nothing new")
    }

    @Test func theFetchStaysReservedUntilTheCountsCatchUp() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        await repo.client.holdLocalBranches(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(await repo.client.fetchCalls == ["origin"])
        #expect(state.fetchStatus == .fetching)
        #expect(state.fetchingRemotes == ["origin"])

        await repo.client.holdLocalBranches(false)
        await repo.client.releaseLocalBranches()
        #expect(await finished(state, as: FetchRound(outcomes: ["origin": .fetched(at: h.clock)])))
    }

    // MARK: New branches

    /// Adopts with `origin/main` present, then runs a round that brings in `origin/feature`,
    /// which is flagged New.
    private func adoptWithNewFeature(_ h: Harness, _ state: WindowState, branches: [LocalBranch]? = nil) async -> (
        root: RepositoryRoot, client: StubRepoClient
    ) {
        let main = remoteBranch("main")
        let repo = h.repo("A", files: [changedFile("a.swift")])
        await repo.client.set(localBranches: branches ?? tracked)
        await repo.client.set(remoteBranches: [main])
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.remoteBranches == [main] })
        await repo.client.holdFetch(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        await repo.client.set(remoteBranches: [main, remoteBranch("feature")])
        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()
        #expect(await finished(state, as: FetchRound(outcomes: ["origin": .fetched(at: h.clock)])))
        #expect(state.newRemoteBranches == [remoteBranch("feature").ref], "main was there before the round")
        return repo
    }

    @Test func newBranchesSurviveAFailedFetchAndClearOnCheckout() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptWithNewFeature(h, state)
        let feature = remoteBranch("feature")

        await repo.client.fail(fetch: true)
        await state.fetchAllRemotes()
        #expect(Self.isFailure(state.lastFetchRound?.outcomes["origin"]))
        #expect(state.newRemoteBranches == [feature.ref], "a failed fetch keeps the flags")

        await state.checkoutRemoteBranch(feature)
        #expect(state.headState == .named("feature"))
        #expect(state.newRemoteBranches.isEmpty)
    }

    /// A post-checkout hook fails after git has moved HEAD: the switch happened, so the
    /// flags go even though the command reported failure.
    @Test func aSwitchThatMovesHeadButFailsItsHookClearsTheNewFlags() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptWithNewFeature(h, state, branches: tracked + [localBranch("topic")])
        await repo.client.set(headStateAfterSwitch: .named("topic"))
        await repo.client.fail(switchBranch: true)

        await state.switchBranch(to: "topic")
        #expect(state.headState == .named("topic"))
        #expect(state.errorMessage != nil)
        #expect(state.newRemoteBranches.isEmpty)
    }

    /// A failed hook followed by a failed HEAD read: whether HEAD moved is unknown, so the
    /// flags go rather than risk outliving the switch.
    @Test func aFailedSwitchWhoseRereadFailsClearsTheNewFlags() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptWithNewFeature(h, state, branches: tracked + [localBranch("topic")])
        await repo.client.fail(switchBranch: true)
        await repo.client.fail(headState: true)

        await state.switchBranch(to: "topic")
        #expect(state.branchReadStatus == .failed)
        #expect(state.errorMessage != nil)
        #expect(state.newRemoteBranches.isEmpty)
    }

    /// A switch that fails without moving HEAD leaves the flags alone.
    @Test func aSwitchThatLeavesHeadKeepsTheNewFlags() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adoptWithNewFeature(h, state, branches: tracked + [localBranch("topic")])
        await repo.client.fail(switchBranch: true)

        await state.switchBranch(to: "topic")
        #expect(state.headState == .named("main"))
        #expect(state.errorMessage != nil)
        #expect(state.newRemoteBranches == [remoteBranch("feature").ref])
    }

    // MARK: Failures

    @Test func aFailedFetchStartsNoCooldown() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        await repo.client.fail(fetch: true)

        state.isBranchPickerPresented = true
        #expect(await eventually { @MainActor in state.fetchStatus == .idle && state.lastFetchRound != nil })
        guard case let .failed(message)? = state.lastFetchRound?.outcomes["origin"] else {
            Issue.record("origin should have failed")
            return
        }
        #expect(!message.isEmpty)
        #expect(state.errorMessage == nil, "header news, never an alert")
        #expect(await repo.client.fetchCalls == ["origin"])

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
        #expect(await eventually { @MainActor in Self.isFailure(state.lastFetchRound?.outcomes["origin"]) })
        state.isBranchPickerPresented = false

        await repo.client.fail(localBranches: true)
        reread(h, repo)
        #expect(await eventually { await state.branchReadStatus == .failed })

        await repo.client.fail(localBranches: false)
        await repo.client.fail(fetch: false)
        await openAndFinish(state, as: FetchRound(outcomes: ["origin": .fetched(at: h.clock)]))
        #expect(await repo.client.fetchCalls == ["origin", "origin"])
        #expect(state.branchReadStatus == .loaded)
    }

    /// The round ends in a branch read even when the cooldown skips every remote.
    @Test func aSuccessfulFetchThenAFailedReadRetriesOnlyTheRead() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        let at = h.clock

        await openAndFinish(state, as: FetchRound(outcomes: ["origin": .fetched(at: at)]))
        state.isBranchPickerPresented = false

        await repo.client.fail(localBranches: true)
        reread(h, repo)
        #expect(await eventually { await state.branchReadStatus == .failed })

        await repo.client.fail(localBranches: false)
        state.isBranchPickerPresented = true
        #expect(await eventually { await state.branchReadStatus == .loaded })
        #expect(await finished(state, as: FetchRound(outcomes: ["origin": .fetched(at: at)])))
        #expect(await repo.client.fetchCalls == ["origin"], "the fetch is still fresh")
    }

    @Test func aFailedRemoteDiscoveryIsReportedAndFetchesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        await repo.client.fail(remoteNames: true)

        state.isBranchPickerPresented = true
        #expect(await eventually { @MainActor in state.fetchStatus == .idle && state.lastFetchRound != nil })
        #expect(state.lastFetchRound?.discoveryError != nil)
        #expect(await repo.client.fetchCalls.isEmpty)
    }

    @Test func anotherRemotesFailureIsReportedUntilItSucceeds() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, remotes: ["origin", "fork"])
        await repo.client.fail(fetch: true, remote: "fork")

        state.isBranchPickerPresented = true
        #expect(await eventually { @MainActor in Self.isFailure(state.lastFetchRound?.outcomes["fork"]) })
        #expect(state.lastFetchRound?.outcomes["origin"] == .fetched(at: h.clock))
        state.isBranchPickerPresented = false

        // fork failed, so it has no cooldown and is fetched again; origin is still fresh.
        await repo.client.fail(fetch: false, remote: "fork")
        let originAt = h.clock
        h.clock += 10
        await openAndFinish(
            state, as: FetchRound(outcomes: ["origin": .fetched(at: originAt), "fork": .fetched(at: h.clock)]))
        #expect(await repo.client.fetchCalls.sorted() == ["fork", "fork", "origin"])
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
        #expect(state.lastFetchRound == nil)
    }

    /// A reopening while the round still lists the remotes joins it rather than starting
    /// another.
    @Test func aReopeningDuringDiscoveryJoinsTheRound() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state)
        await repo.client.holdRemoteNames(true)

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldRemoteNamesCount == 1 })
        state.isBranchPickerPresented = false
        state.isBranchPickerPresented = true
        await settle()

        await repo.client.holdRemoteNames(false)
        await repo.client.releaseRemoteNames()
        #expect(await finished(state, as: FetchRound(outcomes: ["origin": .fetched(at: h.clock)])))
        #expect(await repo.client.remoteNamesCalls == 1)
        #expect(await repo.client.fetchCalls == ["origin"])
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

        #expect(await finished(state, as: FetchRound(outcomes: ["origin": .fetched(at: at)])))
        #expect(await repo.client.localBranchesCalls > readsBefore, "the counts still catch up")

        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.remoteNamesCalls == 2 })
        #expect(await repo.client.fetchCalls == ["origin"], "the cooldown was recorded")
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
        #expect(state.fetchStatus == .fetching, "a closed window publishes nothing")
        #expect(state.lastFetchRound == nil)
        #expect(await repo.client.fetchCalls == ["origin"])
    }
}

/// Pulling and pushing branches from the branch picker's rows.
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

        await state.pull(branch: "main")
        #expect(await repo.client.pullCalls == 0)
        #expect(state.activeSync == nil)

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

        await state.pull(branch: "main")
        #expect(await repo.client.pullCalls == 0, "discovery may yet resolve to origin")
        #expect(state.activeSync == nil)

        await repo.client.holdRemoteNames(false)
        await repo.client.releaseRemoteNames()
    }

    @Test func aPushIsAdmittedWhileAnotherRemoteIsFetched() async {
        let h = Harness()
        let state = h.makeState()
        let feature = localBranch("feature", upstream: upstream("fork/feature", remote: "fork"))
        let repo = await adopt(h, state, branches: main(ahead: 1, behind: 0) + [feature])
        // origin is fetched first, so the next round's cooldown leaves it out.
        state.isBranchPickerPresented = true
        #expect(await eventually { await state.lastFetchRound != nil })
        state.isBranchPickerPresented = false
        await repo.client.set(remoteNames: ["origin", "fork"])
        h.clock += 10
        await repo.client.holdFetch(true, remote: "fork")
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        #expect(state.fetchingRemotes == ["fork"])

        await state.push(branch: "main")
        #expect(await repo.client.pushCalls.map(\.remote) == ["origin"])

        await repo.client.holdFetch(false, remote: "fork")
        await repo.client.releaseFetch()
    }

    /// A fetch can only take a push away, so the push is admitted and waits for it.
    @Test func aPushWaitsForItsRemotesFetch() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main(ahead: 1, behind: 0))
        await repo.client.holdFetch(true)
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })

        let pushing = Task { await state.push(branch: "main") }
        #expect(await eventually { await state.activeSync == ActiveSync(branch: "main", operation: .push) })
        #expect(await repo.client.pushCalls.isEmpty, "the fetch is still running")

        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()
        await pushing.value
        #expect(await repo.client.pushCalls.map(\.remote) == ["origin"])
        #expect(state.activeSync == nil)
    }

    /// The fetch showed the remote moved on, so a fast-forward push would be refused.
    @Test func aPushSkipsWhenItsRemotesFetchDivergesTheBranch() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main(ahead: 1, behind: 0))
        await repo.client.holdFetch(true)
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })

        let pushing = Task { await state.push(branch: "main") }
        #expect(await eventually { await state.activeSync == ActiveSync(branch: "main", operation: .push) })
        await repo.client.set(localBranches: main(ahead: 1, behind: 2))
        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()
        await pushing.value
        #expect(await repo.client.pushCalls.isEmpty)
        #expect(state.errorMessage == nil, "the row says Pull first")
        #expect(state.activeSync == nil)
    }

    /// Discovery that ends while a push runs leaves the remote-tracking refs to the push.
    @Test func discoveryStartsNoFetchWhileAPushRuns() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main(ahead: 1, behind: 0))
        await repo.client.holdRemoteNames(true)
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldRemoteNamesCount == 1 })

        await repo.client.holdPush(true)
        let pushing = Task { await state.push(branch: "main") }
        #expect(await eventually { await repo.client.heldPushCount == 1 })
        await repo.client.holdRemoteNames(false)
        await repo.client.releaseRemoteNames()
        #expect(await eventually { await state.fetchStatus == .idle }, "released as it was before the opening")
        #expect(await repo.client.fetchCalls.isEmpty)

        await repo.client.holdPush(false)
        await repo.client.releasePush()
        await pushing.value
        #expect(await repo.client.pushCalls.map(\.remote) == ["origin"])
        #expect(await repo.client.fetchCalls.isEmpty)
    }

    @Test func aPullIsRefusedWhileABranchSwitchRuns() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main() + [localBranch("feature")])
        await repo.client.holdSwitchBranch(true)
        let switching = Task { await state.switchBranch(to: "feature") }
        #expect(await eventually { await repo.client.heldSwitchBranchCount == 1 })

        await state.pull(branch: "main")
        #expect(await repo.client.pullCalls == 0)
        #expect(state.activeSync == nil)

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
        let pulling = Task { await state.pull(branch: "main") }
        #expect(
            await eventually { await state.activeSync == ActiveSync(branch: "main", operation: .pull) },
            "reserved while it queues")
        #expect(await repo.client.pullCalls == 0, "the write ahead of it still holds the repository")

        await repo.client.holdActions(false)
        await repo.client.releaseActions()
        await action.value
        await pulling.value
        #expect(await repo.client.pullCalls == 1)
        #expect(state.activeSync == nil)
    }

    /// One operation at a time across the picker, whichever row it was started on.
    @Test func anOperationOnOneBranchRefusesAnotherBranchs() async {
        let h = Harness()
        let state = h.makeState()
        let feature = localBranch(
            "feature", upstream: upstream("origin/feature", tracking: .counts(ahead: 1, behind: 0)))
        let repo = await adopt(h, state, branches: main() + [feature])
        await repo.client.holdPull(true)
        let pulling = Task { await state.pull(branch: "main") }
        #expect(await eventually { await repo.client.heldPullCount == 1 })

        await state.push(branch: "feature")
        #expect(await repo.client.pushCalls.isEmpty)
        #expect(state.activeSync == ActiveSync(branch: "main", operation: .pull))

        await repo.client.holdPull(false)
        await repo.client.releasePull()
        await pulling.value
    }

    /// A branch that isn't checked out can only fast-forward.
    @Test func aDivergedBranchThatIsNotCheckedOutIsNotPulled() async {
        let h = Harness()
        let state = h.makeState()
        let feature = localBranch(
            "feature", upstream: upstream("origin/feature", tracking: .counts(ahead: 1, behind: 2)))
        let repo = await adopt(h, state, branches: main() + [feature])

        await state.pull(branch: "feature")
        #expect(await repo.client.fastForwardCalls.isEmpty)
        #expect(await repo.client.pullCalls == 0)
        #expect(state.activeSync == nil)
    }

    // MARK: Revalidation

    @Test func aPullSkipsWhenTheUpstreamMovedToAnotherRemote() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        // What the repository says by the time the pull takes its turn.
        await repo.client.set(localBranches: main(remote: "fork"))

        await state.pull(branch: "main")
        #expect(await repo.client.pullCalls == 0)
        #expect(state.errorMessage == "Branch or upstream changed before the pull could start")
        #expect(state.activeSync == nil)
        #expect(state.currentBranch?.upstream?.remote == "fork", "the branches were re-read")
    }

    @Test func aPullSkipsWhenHeadMovedAway() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.set(headState: .detached(sha: objectID("x")))

        await state.pull(branch: "main")
        #expect(await repo.client.pullCalls == 0)
        #expect(state.errorMessage == "Branch or upstream changed before the pull could start")
    }

    /// Checked-out status picks `git pull` or a fast-forward, so HEAD arriving on the
    /// branch between the click and its turn cancels the fast-forward.
    @Test func aPullSkipsWhenHeadMovedOntoTheBranch() async {
        let h = Harness()
        let state = h.makeState()
        let feature = localBranch(
            "feature", upstream: upstream("origin/feature", tracking: .counts(ahead: 0, behind: 2)))
        let repo = await adopt(h, state, branches: main() + [feature])
        await repo.client.set(headState: .named("feature"))

        await state.pull(branch: "feature")
        #expect(await repo.client.fastForwardCalls.isEmpty)
        #expect(await repo.client.pullCalls == 0)
        #expect(state.errorMessage == "Branch or upstream changed before the pull could start")
        #expect(state.activeSync == nil)
    }

    @Test func aPushSkipsWhenTheUpstreamWasRemoved() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main(ahead: 1, behind: 0))
        await repo.client.set(localBranches: [localBranch("main")])

        await state.push(branch: "main")
        #expect(await repo.client.pushCalls.isEmpty)
        #expect(state.errorMessage == "Branch or upstream changed before the push could start")
    }

    @Test func aPullRunsWhenOnlyTheCountsMoved() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main(behind: 2))
        await repo.client.set(localBranches: main(behind: 3))

        await state.pull(branch: "main")
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

        await state.pull(branch: "main")
        #expect(await repo.client.pullCalls == 0)
        #expect(state.errorMessage == nil)
        #expect(state.currentBranch?.upstream?.tracking == .counts(ahead: 0, behind: 0), "the branches were re-read")
        #expect(state.activeSync == nil)
    }

    @Test func aThrowingRevalidationReleasesTheReservation() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.fail(headState: true)

        await state.pull(branch: "main")
        #expect(await repo.client.pullCalls == 0)
        #expect(state.errorMessage != nil)
        #expect(state.activeSync == nil)
    }

    // MARK: Running

    /// A failed pull can leave conflicts, a merge in progress, or an autostash put back,
    /// so the working tree is re-read either way and the failure is reported after it.
    @Test func aFailedPullStillRefreshesAndReports() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.fail(pull: true)

        await state.pull(branch: "main")
        #expect(await repo.client.pullCalls == 1)
        #expect(h.published.contains { $0.cause == .pull })
        #expect(state.errorMessage != nil)
        #expect(state.activeSync == nil)
    }

    @Test func aPushSendsTheTrackedRefAndRereadsTheCountsOnly() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main(ahead: 2, behind: 0))
        let publishedBefore = h.published.count
        let readsBefore = await repo.client.localBranchesCalls

        await state.push(branch: "main")
        let pushes = await repo.client.pushCalls
        #expect(pushes.map(\.branch) == ["main"])
        #expect(pushes.map(\.remote) == ["origin"])
        #expect(pushes.map(\.remoteRef) == ["refs/heads/main"])
        #expect(h.published.count == publishedBefore, "a push changes no file")
        #expect(await repo.client.localBranchesCalls > readsBefore, "the counts are re-read")
        #expect(state.activeSync == nil)
        #expect(state.errorMessage == nil)
    }

    @Test func aPullOnTheCurrentBranchRunsGitPull() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())

        await state.pull(branch: "main")
        #expect(await repo.client.pullCalls == 1)
        #expect(await repo.client.fastForwardCalls.isEmpty)
        #expect(h.published.contains { $0.cause == .pull })
    }

    @Test func aPullOnAnotherBranchFastForwardsItsRefOnly() async {
        let h = Harness()
        let state = h.makeState()
        let feature = localBranch(
            "feature",
            upstream: upstream(
                "fork/feature", remote: "fork", localRef: "refs/remotes/mirror/feature",
                tracking: .counts(ahead: 0, behind: 2)))
        let repo = await adopt(h, state, branches: main() + [feature])
        let publishedBefore = h.published.count
        let readsBefore = await repo.client.localBranchesCalls

        await state.pull(branch: "feature")
        #expect(await repo.client.pullCalls == 0)
        let calls = await repo.client.fastForwardCalls
        #expect(calls.map(\.branch) == ["feature"])
        #expect(calls.map(\.remote) == ["fork"])
        #expect(calls.map(\.remoteRef) == ["refs/heads/feature"])
        #expect(calls.map(\.localRef) == ["refs/remotes/mirror/feature"])
        #expect(h.published.count == publishedBefore, "no file changed")
        #expect(await repo.client.localBranchesCalls > readsBefore, "the counts are re-read")
        #expect(state.activeSync == nil)
        #expect(state.errorMessage == nil)
    }

    @Test func aFailedFastForwardIsReported() async {
        let h = Harness()
        let state = h.makeState()
        let feature = localBranch(
            "feature", upstream: upstream("origin/feature", tracking: .counts(ahead: 0, behind: 1)))
        let repo = await adopt(h, state, branches: main() + [feature])
        await repo.client.fail(fastForward: true)

        await state.pull(branch: "feature")
        #expect(await repo.client.fastForwardCalls.count == 1)
        #expect(state.errorMessage != nil)
        #expect(state.activeSync == nil)
    }

    @Test func aPushSendsTheBranchItWasAskedFor() async {
        let h = Harness()
        let state = h.makeState()
        let feature = localBranch(
            "feature", upstream: upstream("fork/topic", remote: "fork", tracking: .counts(ahead: 3, behind: 0)))
        let repo = await adopt(h, state, branches: main(behind: 0) + [feature])

        await state.push(branch: "feature")
        let pushes = await repo.client.pushCalls
        #expect(pushes.map(\.branch) == ["feature"])
        #expect(pushes.map(\.remote) == ["fork"])
        #expect(pushes.map(\.remoteRef) == ["refs/heads/topic"])
        #expect(state.activeSync == nil)
    }

    /// The buttons keep their running state until the counts they will be drawn from
    /// have landed, even when a watcher tick takes the operation's own read.
    @Test func aSupersededPostPullReadKeepsTheRunningState() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())

        await repo.client.holdLocalBranches(true)
        let pulling = Task { await state.pull(branch: "main") }
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 }, "the revalidation read")
        await repo.client.releaseFirstLocalBranches()
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 }, "the post-pull read")
        let readsBefore = await repo.client.localBranchesCalls

        // A watcher tick supersedes the post-pull read while it is held.
        h.tick(repo.root, [.refs])
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 2 })
        await repo.client.releaseFirstLocalBranches()
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(
            state.activeSync == ActiveSync(branch: "main", operation: .pull), "still running until a read publishes")
        #expect(await repo.client.localBranchesCalls == readsBefore + 1, "no extra read is started")

        await repo.client.holdLocalBranches(false)
        await repo.client.releaseLocalBranches()
        await pulling.value
        #expect(state.activeSync == nil)
        #expect(await repo.client.pullCalls == 1)
    }

    /// The picker's fetch and a sync move the same counts, so one waits for the other.
    @Test func noFetchStartsWhileASyncIsActive() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: main())
        await repo.client.holdPull(true)

        let pulling = Task { await state.pull(branch: "main") }
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
        let pulling = Task { await state.pull(branch: "main") }
        #expect(await eventually { await state.activeSync == ActiveSync(branch: "main", operation: .pull) })
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

        let pulling = Task { await state.pull(branch: "main") }
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

/// Publishing a branch that tracks nothing from its row.
@MainActor
struct WindowStatePublishTests {
    private let main = localBranch("main", upstream: upstream("origin/main"))
    private let feature = localBranch("feature")

    private func adopt(_ h: Harness, _ state: WindowState, branches: [LocalBranch], remotes: [String]) async -> (
        root: RepositoryRoot, client: StubRepoClient
    ) {
        let repo = h.repo("A", files: [changedFile("a.swift")])
        await repo.client.set(localBranches: branches)
        await repo.client.set(remoteNames: remotes)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.branchReadStatus == .loaded })
        return repo
    }

    /// Opens the picker, which reads the remotes Publish chooses from, and waits for its
    /// fetches to finish.
    private func openPicker(_ state: WindowState, remotes: [String]) async {
        state.isBranchPickerPresented = true
        #expect(
            await eventually { @MainActor in
                state.remotes == remotes && state.fetchStatus == .idle
            })
    }

    @Test func aPublishSendsTheBranchToTheChosenRemote() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [localBranch("main"), feature], remotes: ["fork", "upstream"])
        await openPicker(state, remotes: ["fork", "upstream"])
        let readsBefore = await repo.client.localBranchesCalls

        await state.publish(branch: "feature", to: "upstream")
        let calls = await repo.client.publishCalls
        #expect(calls.map(\.branch) == ["feature"])
        #expect(calls.map(\.remote) == ["upstream"])
        #expect(await repo.client.localBranchesCalls > readsBefore, "the branches are re-read")
        #expect(state.activeSync == nil)
        #expect(state.errorMessage == nil)
    }

    /// Under a narrow fetch mapping the published branch reads back as tracking nothing;
    /// the config the publish wrote is what keeps its row from offering Publish again.
    @Test func aPublishRemembersItsUpstreamWhenTheConfigRereadFails() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [main, feature], remotes: ["origin"])
        await openPicker(state, remotes: ["origin"])
        await repo.client.holdPublish(true)

        let publishing = Task { await state.publish(branch: "feature", to: "origin") }
        #expect(await eventually { await repo.client.heldPublishCount == 1 })
        await repo.client.fail(configuredUpstreamRemotes: true)
        await repo.client.holdPublish(false)
        await repo.client.releasePublish()
        await publishing.value

        #expect(state.configuredUpstreamRemotes["feature"] == "origin")
        #expect(state.errorMessage == nil)
        #expect(state.activeSync == nil)
    }

    @Test func aPublishIsCancelledWhenTheBranchGainedAnUpstream() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [main, feature], remotes: ["origin"])
        await openPicker(state, remotes: ["origin"])
        // What the repository says by the time the publish takes its turn.
        let published = localBranch("feature", upstream: upstream("origin/feature"))
        await repo.client.set(localBranches: [main, published])

        await state.publish(branch: "feature", to: "origin")
        #expect(await repo.client.publishCalls.isEmpty)
        #expect(state.errorMessage == "Branch or upstream changed before the publish could start")
        #expect(state.branches.contains(published), "the branches were re-read")
        #expect(state.activeSync == nil)
    }

    @Test func aPublishIsCancelledWhenFetchSettingsHideAnUpstream() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [main, feature], remotes: ["origin"])
        await openPicker(state, remotes: ["origin"])
        await repo.client.set(configuredUpstreamRemotes: ["main": "origin", "feature": "origin"])

        await state.publish(branch: "feature", to: "origin")
        #expect(await repo.client.publishCalls.isEmpty)
        #expect(state.errorMessage == "feature tracks origin, but fetch settings don't fetch it")
        #expect(state.configuredUpstreamRemotes["feature"] == "origin", "the row can say so now")
        #expect(state.activeSync == nil)
    }

    @Test func aPublishWaitsOnItsRemotesFetch() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [main, feature], remotes: ["origin"])
        await repo.client.holdFetch(true)
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })

        await state.publish(branch: "feature", to: "origin")
        #expect(await repo.client.publishCalls.isEmpty)
        #expect(state.activeSync == nil)

        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()
        await openPicker(state, remotes: ["origin"])
        await state.publish(branch: "feature", to: "origin")
        #expect(await repo.client.publishCalls.map(\.remote) == ["origin"])
    }

    @Test func aPublishIsAdmittedWhileAnotherRemoteIsFetched() async {
        let h = Harness()
        let state = h.makeState()
        let onFork = localBranch("main", upstream: upstream("fork/main", remote: "fork"))
        let repo = await adopt(h, state, branches: [onFork, feature], remotes: ["origin"])
        // origin is fetched first, so the next round's cooldown leaves it out.
        await openPicker(state, remotes: ["origin"])
        state.isBranchPickerPresented = false
        await repo.client.set(remoteNames: ["origin", "fork"])
        h.clock += 10
        await repo.client.holdFetch(true, remote: "fork")
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        #expect(state.fetchingRemotes == ["fork"])

        await state.publish(branch: "feature", to: "origin")
        #expect(await repo.client.publishCalls.map(\.remote) == ["origin"])

        await repo.client.holdFetch(false, remote: "fork")
        await repo.client.releaseFetch()
    }
}

/// Deleting a branch whose upstream is gone from its row.
@MainActor
struct WindowStateDeleteTests {
    private let main = localBranch("main", upstream: upstream("origin/main"))
    private let feature = localBranch("feature", upstream: upstream("origin/feature", tracking: .gone))

    private func adopt(_ h: Harness, _ state: WindowState, branches: [LocalBranch]) async -> (
        root: RepositoryRoot, client: StubRepoClient
    ) {
        let repo = h.repo("A", files: [changedFile("a.swift")])
        await repo.client.set(localBranches: branches)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.branchReadStatus == .loaded })
        return repo
    }

    // MARK: Running

    @Test func aGoneBranchIsDeletedAndItsConfigForgotten() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [main, feature])
        await repo.client.set(configuredUpstreamRemotes: ["main": "origin", "feature": "origin"])
        state.isBranchPickerPresented = true
        #expect(
            await eventually { @MainActor in
                state.configuredUpstreamRemotes["feature"] == "origin" && state.fetchStatus == .idle
            })

        await state.deleteBranch(feature)
        #expect(await repo.client.deleteBranchCalls == ["feature"])
        #expect(state.branches == [main], "the branches were re-read")
        #expect(state.configuredUpstreamRemotes["feature"] == nil)
        #expect(state.errorMessage == nil)
        #expect(state.activeSync == nil)
    }

    @Test func aFailedDeleteIsReported() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [main, feature])
        await repo.client.fail(deleteBranch: true)

        await state.deleteBranch(feature)
        #expect(await repo.client.deleteBranchCalls == ["feature"])
        #expect(state.errorMessage != nil)
        #expect(state.branches.contains(feature))
        #expect(state.activeSync == nil)
    }

    // MARK: Admission

    /// The fetch may bring the remote branch back, and the row would stop being gone.
    @Test func aDeleteIsRefusedWhileItsRemoteIsFetched() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [main, feature])
        await repo.client.holdFetch(true)
        state.isBranchPickerPresented = true
        #expect(await eventually { await repo.client.heldFetchCount == 1 })
        #expect(state.fetchingRemotes == ["origin"])

        await state.deleteBranch(feature)
        #expect(await repo.client.deleteBranchCalls.isEmpty)
        #expect(state.activeSync == nil)

        await repo.client.holdFetch(false)
        await repo.client.releaseFetch()
    }

    @Test func aDeleteIsRefusedUnlessTheListShowsTheBranchGone() async {
        let h = Harness()
        let state = h.makeState()
        let tracked = localBranch("feature", upstream: upstream("origin/feature"))
        let repo = await adopt(h, state, branches: [main, tracked])

        await state.deleteBranch(feature)
        #expect(await repo.client.deleteBranchCalls.isEmpty, "the list shows its upstream")
        #expect(state.activeSync == nil)

        let currentGone = localBranch("main", upstream: upstream("origin/main", tracking: .gone))
        await repo.client.set(localBranches: [currentGone])
        h.tick(repo.root, [.refs])
        #expect(await eventually { await state.branches == [currentGone] })
        await state.deleteBranch(currentGone)
        #expect(await repo.client.deleteBranchCalls.isEmpty, "checked out")
        #expect(state.activeSync == nil)
    }

    // MARK: Revalidation

    /// The name was reused, retargeted, or checked out between the confirmation and the
    /// delete's turn: that is another branch now, and it is left alone.
    @Test func aDeleteSkipsABranchThatChangedBeforeItsTurn() async {
        let moved = localBranch("feature", upstream: feature.upstream, tipSha: objectID("other"))
        let retargeted = localBranch("feature", upstream: upstream("fork/feature", remote: "fork", tracking: .gone))
        let changes: [(branches: [LocalBranch], head: HeadState)] = [
            ([main, moved], .named("main")),
            ([main, retargeted], .named("main")),
            ([main, feature], .named("feature")),
        ]
        for change in changes {
            let h = Harness()
            let state = h.makeState()
            let repo = await adopt(h, state, branches: [main, feature])
            // What the repository says by the time the delete takes its turn.
            await repo.client.set(localBranches: change.branches)
            await repo.client.set(headState: change.head)

            await state.deleteBranch(feature)
            #expect(await repo.client.deleteBranchCalls.isEmpty)
            #expect(state.errorMessage == "Branch or upstream changed before the delete could start")
            #expect(state.activeSync == nil)
        }
    }

    @Test func aBranchAlreadyDeletedIsSkippedSilently() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [main, feature])
        await repo.client.set(localBranches: [main])

        await state.deleteBranch(feature)
        #expect(await repo.client.deleteBranchCalls.isEmpty)
        #expect(state.errorMessage == nil)
        #expect(state.branches == [main])
    }

    // MARK: Ordering

    @Test func aSwitchToTheBranchBeingDeletedIsRefusedButAnotherQueues() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await adopt(h, state, branches: [main, feature, localBranch("other")])
        await repo.client.holdLocalBranches(true)
        let deleting = Task { await state.deleteBranch(feature) }
        #expect(await eventually { await repo.client.heldLocalBranchesCount == 1 })
        #expect(state.activeSync == ActiveSync(branch: "feature", operation: .delete))

        await state.switchBranch(to: "feature")
        #expect(!state.isSwitchingBranch)
        let switching = Task { await state.switchBranch(to: "other") }
        #expect(await eventually { await state.isSwitchingBranch })
        #expect(await repo.client.switchBranchCalls.isEmpty, "queued behind the delete")

        await repo.client.holdLocalBranches(false)
        await repo.client.releaseLocalBranches()
        await deleting.value
        await switching.value
        #expect(await repo.client.deleteBranchCalls == ["feature"])
        #expect(await repo.client.switchBranchCalls == ["other"])
    }
}
