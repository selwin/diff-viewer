import AppKit
import Testing

@testable import DiffViewer

/// One staged file, so a commit is possible, and one unstaged file for the writes that
/// are queued around a switch.
private let filesStaged = [changedFile("a.swift", area: .staged), changedFile("b.swift")]
private let message = "Add the picker"
/// The stub's head and the branch it starts on.
private let mainHead = String(repeating: "a", count: 40)

/// A window and the repository behind it.
private typealias Window = (h: Harness, state: WindowState, client: StubRepoClient, root: RepositoryRoot)

@MainActor
struct WindowStateBranchSwitchTests {
    // MARK: Fixtures

    /// A window adopted and waited on past the first file list, the commit list, HEAD
    /// and the branch list, so every baseline is stable before the test acts.
    private func settled(files: [ChangedFile] = filesStaged, commits: [CommitSummary] = []) async throws -> Window {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: files)
        await repo.client.set(commits: commits)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await h.published.count == 1 })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        let historyTask = try #require(state.session?.historyTask)
        await historyTask.value
        #expect(await eventually { await state.localBranches == ["main"] })
        #expect(state.headState == .named("main"))
        return (h, state, repo.client, repo.root)
    }

    /// Tells the stub what a switch to `branch` leaves behind: a new HEAD unless the
    /// branch sits on the current commit.
    private func stubSwitch(_ client: StubRepoClient, to branch: String, movesHead: Bool = true) async {
        await client.set(headStateAfterSwitch: .named(branch))
        await client.set(headAfterSwitch: movesHead ? objectID(branch) : mainHead)
    }

    /// Holds the switch itself, starts one and waits until git has it: the shape of
    /// every test that drives something while a switch is in flight.
    private func startHeldSwitch(_ state: WindowState, _ client: StubRepoClient) async -> Task<Void, Never> {
        await client.holdSwitchBranch(true)
        let task = Task { await state.switchBranch(to: "side") }
        #expect(await eventually { await client.heldSwitchBranchCount == 1 })
        #expect(state.isSwitchingBranch)
        return task
    }

    /// Lets the held switch through and waits for it to finish.
    private func release(_ task: Task<Void, Never>, _ client: StubRepoClient) async {
        await client.holdSwitchBranch(false)
        await client.releaseSwitchBranch()
        await task.value
    }

    // MARK: Switching

    /// The whole successful path in one: git gets the branch, the list is re-read because
    /// the watcher ignores this process's own writes, and history and HEAD follow.
    @Test func switchCallsGitThenRefreshesListHistoryAndHead() async throws {
        let (h, state, client, _) = try await settled()
        await stubSwitch(client, to: "side")

        await state.switchBranch(to: "side")

        #expect(await client.switchBranchCalls == ["side"])
        #expect(h.published.last?.cause == .branchSwitch)
        #expect(state.headState == .named("side"))
        // The history load is fire-and-forget, so its read lands after `switchBranch` returns.
        #expect(await eventually { await state.history.revision == objectID("side") })
        #expect(!state.isSwitchingBranch)
        #expect(state.errorMessage == nil)
    }

    /// A commit's files and diff cannot change under a checkout, so commit scope re-reads
    /// neither; only the branch and its history can have moved.
    @Test func switchInCommitScopeReloadsHistoryAndHeadButNotTheCommit() async throws {
        let commit = commitSummary("c1")
        let (h, state, client, _) = try await settled(commits: [commit])
        await client.set(files: [changedFile("one.swift", area: .commit(commit.ref))], forCommit: commit.ref.sha)
        state.select(commit: commit)
        #expect(await eventually { await h.published.last?.cause == .scope })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
        let commitReads = await client.commitFileCalls
        let contentReads = await client.contentReads
        let publishes = h.published.count
        await stubSwitch(client, to: "side")

        await state.switchBranch(to: "side")

        #expect(await client.switchBranchCalls == ["side"])
        #expect(await client.commitFileCalls == commitReads, "the commit's files were not re-read")
        #expect(h.published.count == publishes, "and no list was republished")
        #expect(state.headState == .named("side"))
        #expect(await eventually { await state.history.revision == objectID("side") })
        #expect(await client.contentReads == contentReads, "the diff was not reloaded")
        #expect(!state.diffLoader.hasActiveWork)
        #expect(state.scope == .commit(commit.ref))
        #expect(state.selectedCommit == commit)
    }

    /// A refused switch is news the reader has not seen, so it outlives the refresh that
    /// follows it and the next one too.
    @Test func switchFailureShowsGitsMessageAfterTheRefresh() async throws {
        let (h, state, client, root) = try await settled()
        await client.fail(switchBranch: true)

        await state.switchBranch(to: "side")

        #expect(state.errorMessage?.contains("post-checkout hook failed") == true)
        #expect(h.published.last?.cause == .branchSwitch)
        #expect(state.headState == .named("main"))
        #expect(!state.isSwitchingBranch)

        let publishes = h.published.count
        h.watcherCallbacks[root]!()
        #expect(await eventually { await h.published.count > publishes })
        #expect(state.errorMessage?.contains("post-checkout hook failed") == true, "a watcher refresh keeps it")
    }

    /// The case the refresh-either-way exists for: a post-checkout hook fails after git
    /// has already moved HEAD, so the error and the new branch are both true.
    @Test func switchFailureWithMovedHeadStillPublishesTheNewBranch() async throws {
        let (_, state, client, _) = try await settled()
        await client.fail(switchBranch: true)
        await stubSwitch(client, to: "side")

        await state.switchBranch(to: "side")

        #expect(state.errorMessage?.contains("post-checkout hook failed") == true)
        #expect(state.headState == .named("side"))
        #expect(await eventually { await state.history.revision == objectID("side") })
    }

    /// The switch replaced the working tree, so branch A's rows must not stay on screen
    /// under branch B's name when the re-read fails, and nothing they enabled may stay
    /// actionable. The next successful tick fills the list again.
    @Test func switchWithAFailedStatusReadLeavesNothingStale() async throws {
        let (h, state, client, root) = try await settled()
        state.commitMessage = message
        #expect(state.canCommit)
        await stubSwitch(client, to: "side")
        await client.fail(true)

        await state.switchBranch(to: "side")

        #expect(state.files.isEmpty)
        #expect(state.listReadFailed, "an empty list here is unread, not clean")
        #expect(!state.isLoadingScope)
        #expect(!state.canCommit)
        #expect(state.errorMessage != nil)
        #expect(state.headState == .named("side"))
        #expect(!state.isSwitchingBranch)

        await client.fail(false)
        let publishes = h.published.count
        h.watcherCallbacks[root]!()
        #expect(await eventually { await state.files == filesStaged })
        #expect(h.published.count == publishes + 1)
        #expect(!state.listReadFailed)
        #expect(state.canCommit, "the draft survived and the list is back")
        #expect(state.errorMessage == nil, "a successful refresh clears the error a refresh raised")
    }

    /// git refused and left the repository as it was, so the reader's row is still there
    /// and still theirs: the switch must not have moved them off it.
    @Test func aRefusedSwitchKeepsTheSelectedFile() async throws {
        let (h, state, client, _) = try await settled()
        await client.fail(switchBranch: true)
        state.selection = [.file(filesStaged[1].id)]

        await state.switchBranch(to: "side")

        #expect(h.published.last?.cause == .branchSwitch)
        #expect(state.selection == [.file(filesStaged[1].id)])
        #expect(state.errorMessage != nil)
    }

    /// A local change that survives the checkout is still the reader's row, whichever
    /// branch it now sits on.
    @Test func aSuccessfulSwitchKeepsASelectedPathThatSurvives() async throws {
        let (h, state, client, _) = try await settled()
        state.selection = [.file(filesStaged[1].id)]
        await stubSwitch(client, to: "side")
        await client.set(files: [changedFile("side.swift"), filesStaged[1]])

        await state.switchBranch(to: "side")

        #expect(h.published.last?.cause == .branchSwitch)
        #expect(state.headState == .named("side"))
        #expect(state.selection == [.file(filesStaged[1].id)])
    }

    /// Nothing selected came back, and All changes shows the new list whole.
    @Test func switchLandsOnAllChangesWhenSelectedPathsDisappear() async throws {
        let (h, state, client, _) = try await settled()
        state.selection = [.file(filesStaged[1].id)]
        await stubSwitch(client, to: "side")
        await client.set(files: [changedFile("side.swift")])

        await state.switchBranch(to: "side")

        #expect(h.published.last?.cause == .branchSwitch)
        #expect(state.files.map(\.path) == ["side.swift"])
        #expect(state.selection == [.allChanges])
    }

    /// Two branches on one commit: the picker's face changes and nothing else does, so
    /// the page the reader scrolled to stays where it was.
    @Test func switchBetweenBranchesAtTheSameCommitUpdatesTheFaceWithoutReloadingHistory() async throws {
        let (_, state, client, _) = try await settled()
        await stubSwitch(client, to: "twin", movesHead: false)
        let historyReads = await client.historyCalls

        await state.switchBranch(to: "twin")

        #expect(state.branchDisplayTitle == "twin")
        #expect(state.currentBranchName == "twin")
        #expect(await client.historyCalls == historyReads)
        #expect(state.history.revision == mainHead)
        #expect(state.errorMessage == nil)
    }

    /// Choosing the ticked branch is not a request.
    @Test func switchToTheCurrentBranchDoesNothing() async throws {
        let (h, state, client, _) = try await settled()
        let statusReads = await client.statusCalls
        let publishes = h.published.count

        await state.switchBranch(to: "main")

        #expect(await client.switchBranchCalls.isEmpty)
        #expect(await client.statusCalls == statusReads)
        #expect(h.published.count == publishes)
        #expect(!state.isSwitchingBranch)
    }

    /// A page count built up by Load More belongs to the branch it was read from: a
    /// different HEAD starts again from one page.
    @Test func switchAfterManyPagesResetsTheLimit() async throws {
        // Two pages and one more, so `hasMore` holds through two Load Mores.
        let commits = (0...WindowState.commitPageSize * 2).map { commitSummary("c\($0)") }
        let (_, state, client, _) = try await settled(commits: commits)
        #expect(state.history.hasMore)
        for _ in 0..<2 {
            state.loadMoreCommits()
            let load = try #require(state.session?.historyTask)
            await load.value
        }
        #expect(state.commitLimit == WindowState.commitPageSize * 3)
        #expect(await client.lastHistoryLimit == WindowState.commitPageSize * 3 + 1)
        await stubSwitch(client, to: "side")

        await state.switchBranch(to: "side")

        #expect(await eventually { await state.history.revision == objectID("side") })
        #expect(state.commitLimit == WindowState.commitPageSize)
        #expect(await client.lastHistoryLimit == WindowState.commitPageSize + 1)
        #expect(await client.lastHistoryRevision == objectID("side"))
    }

    // MARK: The write queue

    /// A switch rides the same serialized chain as the sidebar's writes, so it can never
    /// meet a stage on `index.lock`.
    @Test func switchWaitsBehindAHeldStage() async throws {
        let (_, state, client, _) = try await settled()
        await client.holdActions(true)
        let stage = Task { await state.perform(.stage, on: [filesStaged[1]]) }
        #expect(await eventually { await client.heldActionCount == 1 })

        let switchTask = Task { await state.switchBranch(to: "side") }
        #expect(await eventually { await state.isSwitchingBranch })
        #expect(await client.switchBranchCalls.isEmpty, "queued, not started")

        await client.holdActions(false)
        await client.releaseActions()
        await stage.value
        await switchTask.value

        #expect(await client.switchBranchCalls == ["side"])
        #expect(!state.isSwitchingBranch)
    }

    /// A burst of picks records one switch: the admission guard is set before the first
    /// suspension, so the second call finds one already queued and returns.
    @Test func secondSwitchWhileOneIsPendingIsRejected() async throws {
        let (_, state, client, _) = try await settled()
        let switchTask = await startHeldSwitch(state, client)

        await state.switchBranch(to: "other")
        #expect(await client.switchBranchCalls == ["side"])

        await release(switchTask, client)
        #expect(await client.switchBranchCalls == ["side"])
    }

    /// The box is closed to a commit while a switch is pending: the index it would record
    /// is about to belong to another branch.
    @Test func commitRequestedDuringAPendingSwitchIsRefused() async throws {
        let (_, state, client, _) = try await settled()
        state.commitMessage = message
        #expect(state.canCommit)
        let switchTask = await startHeldSwitch(state, client)

        #expect(!state.canCommit)
        await state.commit()
        #expect(await client.commitMessages.isEmpty)

        await release(switchTask, client)
        #expect(await client.commitMessages.isEmpty)
        #expect(state.canCommit, "open again once the switch is over")
    }

    /// A sidebar write during a pending switch never enters the queue, not even its
    /// status read.
    @Test func discardRequestedDuringAPendingSwitchIsRefused() async throws {
        let (_, state, client, _) = try await settled()
        let switchTask = await startHeldSwitch(state, client)
        let statusReads = await client.statusCalls

        await state.perform(.discard, on: [filesStaged[1]])
        #expect(await client.performed.isEmpty)
        #expect(await client.statusCalls == statusReads)

        await release(switchTask, client)
        #expect(await client.performed.isEmpty)
    }

    /// Reveal, Open, and Copy Path touch nothing in the repository, so a pending switch
    /// is no reason to refuse them.
    @Test func copyPathStaysAvailableDuringAPendingSwitch() async throws {
        let (_, state, client, root) = try await settled()
        let switchTask = await startHeldSwitch(state, client)

        await state.perform(.copyPath, on: [filesStaged[1]])
        #expect(NSPasteboard.general.string(forType: .string) == root.url.appendingPathComponent("b.swift").path)

        await release(switchTask, client)
    }

    // MARK: Closing

    /// git was already running when the window closed, so the switch itself stands; what
    /// a closed window must not do is publish a list, a branch, or an alert nobody can see.
    @Test func closeWhileSwitchIsHeldPublishesNothing() async throws {
        let (h, state, client, _) = try await settled()
        await client.fail(switchBranch: true)
        await stubSwitch(client, to: "side")
        await client.set(localBranches: ["main", "side"])
        let switchTask = await startHeldSwitch(state, client)

        let publishes = h.published.count
        let historyReads = await client.historyCalls
        let branchReads = await client.localBranchesCalls
        state.close()
        await release(switchTask, client)

        #expect(h.published.count == publishes)
        #expect(state.errorMessage == nil)
        #expect(state.headState == .named("main"))
        #expect(state.localBranches == ["main"])
        #expect(await client.localBranchesCalls == branchReads)
        #expect(await client.historyCalls == historyReads)
        #expect(!state.isSwitchingBranch)
    }

    /// `refresh` returns quietly for a closed window; the HEAD check and the head-state
    /// read after it need guards of their own, or a closed window would start processes.
    @Test func closeDuringSwitchRefreshPublishesNothing() async throws {
        let (h, state, client, _) = try await settled()
        await client.fail(switchBranch: true)
        await stubSwitch(client, to: "side")
        let switchTask = await startHeldSwitch(state, client)
        // Every status read from here on is held, so the switch's own refresh waits.
        await client.hold(true)
        await client.holdSwitchBranch(false)
        await client.releaseSwitchBranch()
        #expect(await eventually { await client.heldCount == 1 })

        let publishes = h.published.count
        let headChecks = await client.headCalls
        let headStateReads = await client.headStateCalls
        state.close()
        await client.hold(false)
        await client.releaseFirst()
        await switchTask.value

        #expect(h.published.count == publishes)
        #expect(state.errorMessage == nil)
        #expect(state.headState == .named("main"))
        #expect(await client.headCalls == headChecks, "no HEAD check was even started")
        #expect(await client.headStateCalls == headStateReads)
        #expect(!state.isLoadingHistory)
        #expect(!state.isSwitchingBranch)
    }

    // MARK: The branch list

    /// The list rides the head-state read, so every watcher tick keeps it current.
    @Test func headRefreshUpdatesLocalBranches() async throws {
        let (h, state, client, root) = try await settled()
        await client.set(localBranches: ["a", "b"])

        h.watcherCallbacks[root]!()
        #expect(await eventually { await state.localBranches == ["a", "b"] })
    }

    /// A read that threw knows nothing, so the picker keeps its last good list rather
    /// than emptying for one bad moment.
    @Test func aFailedBranchesReadKeepsThePreviousList() async throws {
        let (h, state, client, root) = try await settled()
        await client.fail(localBranches: true)
        await client.set(localBranches: ["a", "b"])
        // Waiting for the failing read to be counted, rather than for a duration, keeps
        // the assertion below about the list and not about timing.
        let reads = await client.localBranchesCalls
        h.watcherCallbacks[root]!()
        #expect(await eventually { await client.localBranchesCalls == reads + 1 })
        #expect(state.localBranches == ["main"])
    }

    /// Two reads in flight at once: the newer one finishes first and the older must apply
    /// nothing, or the picker would list a branch that has since been deleted.
    @Test func anOlderBranchesReadCannotOverwriteANewerOne() async throws {
        let (_, state, client, _) = try await settled()
        await client.set(localBranches: ["main", "older"])
        await client.holdLocalBranches(true)
        // ⌘R rather than a watcher tick: it awaits the head-state read, so the test can
        // tell when the older read has finished and applied nothing.
        let older = Task { await state.refresh() }
        #expect(await eventually { await client.heldLocalBranchesCount == 1 })
        await client.set(localBranches: ["main"])
        let newer = Task { await state.refresh() }
        #expect(await eventually { await client.heldLocalBranchesCount == 2 })

        await client.releaseLastLocalBranches()
        await newer.value
        #expect(state.localBranches == ["main"])

        await client.holdLocalBranches(false)
        await client.releaseLocalBranches()
        await older.value
        #expect(state.localBranches == ["main"], "the older read finished and applied nothing")
    }

    // MARK: Presentation

    @Test func scopeDisplayTitleNamesTheWorkingTreeOrTheCommit() async throws {
        let commit = commitSummary("c1", subject: "Add the picker")
        let (h, state, _, _) = try await settled(commits: [commit])
        #expect(state.scopeDisplayTitle == "Working Tree")

        state.select(commit: commit)
        #expect(state.scopeDisplayTitle == "Add the picker · \(commit.ref.shortSha)")
        #expect(await eventually { await h.published.last?.cause == .scope })
    }
}
