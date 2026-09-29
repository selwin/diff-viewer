import Foundation
import Testing

@testable import DiffViewer

/// The working tree's churn the tab bar and the commit picker show, in either scope.
@MainActor
struct WindowStateWorkingTreeChurnTests {
    private let workingFiles = [changedFile("a.swift"), changedFile("a.swift", area: .staged), changedFile("b.swift")]
    /// `workingFiles` with the counts `setCounts` stubs: a path in both areas counts once
    /// as a file and twice in the lines.
    private static let churn = RepositoryChurn(changedFileCount: 2, added: 15, deleted: 5)
    private let commit = commitSummary("c1")

    private func setCounts(_ client: StubRepoClient) async {
        await client.set(numstat: [row("a.swift", 3, 1), row("b.swift", 2, 0)], area: .unstaged)
        await client.set(numstat: [row("a.swift", 10, 4)], area: .staged)
    }

    private func row(_ path: String, _ added: Int, _ deleted: Int) -> NumstatEntry {
        NumstatEntry(path: path, stats: .counted(added: added, deleted: deleted))
    }

    /// A window showing `commit`, with the working tree's churn already published.
    private func showingCommit(
        branches: [LocalBranch]? = nil
    ) async -> (h: Harness, state: WindowState, client: StubRepoClient) {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: workingFiles)
        await setCounts(repo.client)
        await repo.client.set(head: commit.ref.sha)
        await repo.client.set(commits: [commit])
        if let branches { await repo.client.set(localBranches: branches) }
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.workingTreeChurn == Self.churn })
        #expect(await eventually { await !state.history.commits.isEmpty })
        #expect(await eventually { await state.branchReadStatus == .loaded })
        state.select(commit: commit)
        #expect(await eventually { await h.published.last?.cause == .scope })
        return (h, state, repo.client)
    }

    // MARK: Working-tree scope

    /// The churn waits for the line counts, so the tab never shows a list whose lines
    /// are missing: not on the first list, and not when a tick adds a file.
    @Test func theChurnIsTheAllChangesTotalOnceTheCountsAreIn() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: workingFiles)
        await setCounts(repo.client)
        await repo.client.holdNumstat(true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await !h.published.isEmpty })
        #expect(await eventually { await repo.client.heldNumstatCount == 2 })
        #expect(state.workingTreeChurn == nil)

        await repo.client.releaseNumstat()
        #expect(await eventually { await state.workingTreeChurn == Self.churn })
        #expect(LineStats.total(of: state.files) == .counted(added: Self.churn.added, deleted: Self.churn.deleted))

        let published = h.published.count
        await repo.client.set(files: workingFiles + [changedFile("c.swift")])
        let unstaged = [row("a.swift", 3, 1), row("b.swift", 2, 0), row("c.swift", 7, 0)]
        await repo.client.set(numstat: unstaged, area: .unstaged)
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await h.published.count > published })
        #expect(await eventually { await repo.client.heldNumstatCount == 2 })
        #expect(state.files.contains { $0.path == "c.swift" && $0.lineStats == nil }, "the list is out, uncounted")
        #expect(state.workingTreeChurn == Self.churn)

        await repo.client.releaseNumstat()
        #expect(
            await eventually {
                await state.workingTreeChurn == RepositoryChurn(changedFileCount: 3, added: 22, deleted: 5)
            })
    }

    /// Untracked lines are counted from the worktree, so they survive a failed numstat.
    @Test func aFailedNumstatStillPublishesTheChurn() async {
        let h = Harness()
        let state = h.makeState()
        let files = [changedFile("a.swift"), changedFile("new.txt", kind: .untracked)]
        let repo = h.repo("A", files: files)
        await repo.client.set(worktree: Data("a\nb\n".utf8), for: "new.txt")
        await repo.client.fail(numstat: true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(
            await eventually {
                await state.workingTreeChurn == RepositoryChurn(changedFileCount: 2, added: 2, deleted: 0)
            })
    }

    @Test func aFailedWorkingTreeRefreshLeavesNoChurn() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: workingFiles)
        await setCounts(repo.client)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.workingTreeChurn == Self.churn })

        await repo.client.fail(true)
        await state.refresh()
        #expect(state.workingTreeChurn == nil)
    }

    /// Selecting a commit cancels the line-count read the churn was waiting on, so a
    /// churn read of its own takes over.
    @Test func leavingTheWorkingTreeMidCountStillPublishesTheChurn() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: workingFiles)
        await setCounts(repo.client)
        await repo.client.set(commits: [commit])
        await repo.client.holdNumstat(true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await repo.client.heldNumstatCount == 2 })
        #expect(await eventually { await !state.history.commits.isEmpty })

        state.select(commit: commit)
        // The cancelled read's two, the commit's own count, and the churn read's two.
        #expect(await eventually { await repo.client.heldNumstatCount == 5 })
        #expect(state.workingTreeChurn == nil)
        await repo.client.releaseNumstat()
        #expect(await eventually { await state.workingTreeChurn == Self.churn })
    }

    /// The scope change drops the first list's status read, so the churn it would have
    /// published comes from a read of its own.
    @Test func selectingACommitDuringTheFirstStatusReadStillPublishesTheChurn() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: workingFiles)
        await setCounts(repo.client)
        await repo.client.set(commits: [commit])
        await repo.client.hold(true)
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await repo.client.heldCount == 1 })
        #expect(await eventually { await !state.history.commits.isEmpty })

        state.select(commit: commit)
        #expect(await eventually { await repo.client.heldCount == 2 })
        await repo.client.hold(false)
        await repo.client.releaseFirst()
        await repo.client.releaseFirst()
        #expect(await eventually { await state.workingTreeChurn == Self.churn })
    }

    /// The same for a tick's status read, when an older churn is already on the tab.
    @Test func selectingACommitDuringATicksStatusReadStillUpdatesTheChurn() async {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: workingFiles)
        await setCounts(repo.client)
        await repo.client.set(commits: [commit])
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.workingTreeChurn == Self.churn })
        #expect(await eventually { await !state.history.commits.isEmpty })

        await repo.client.set(files: [changedFile("x.swift")])
        await repo.client.set(numstat: [row("x.swift", 4, 2)], area: .unstaged)
        await repo.client.set(numstat: [], area: .staged)
        await repo.client.hold(true)
        h.watcherCallbacks[repo.root]!()
        #expect(await eventually { await repo.client.heldCount == 1 })

        state.select(commit: commit)
        #expect(await eventually { await repo.client.heldCount == 2 })
        await repo.client.hold(false)
        await repo.client.releaseFirst()
        await repo.client.releaseFirst()
        #expect(
            await eventually {
                await state.workingTreeChurn == RepositoryChurn(changedFileCount: 1, added: 4, deleted: 2)
            })
    }

    // MARK: Commit scope

    /// The watcher ignores this app's own writes, so a pull re-reads the churn itself.
    @Test func aPullWhileACommitIsShownUpdatesTheChurn() async {
        let tracking = upstream("origin/main", tracking: .counts(ahead: 0, behind: 2))
        let (_, state, client) = await showingCommit(branches: [localBranch("main", upstream: tracking)])
        await client.set(files: [changedFile("x.swift")])
        await client.set(numstat: [row("x.swift", 4, 2)], area: .unstaged)
        await client.set(numstat: [], area: .staged)

        await state.pull(branch: "main")
        #expect(await client.pullCalls == 1)
        #expect(state.workingTreeChurn == RepositoryChurn(changedFileCount: 1, added: 4, deleted: 2))
    }

    @Test func aCleanTreesChurnReadRunsNoNumstat() async {
        let (h, state, client) = await showingCommit()
        await h.settleStats(state)
        let numstats = await client.numstatCalls
        await client.set(files: [])

        h.watcherCallbacks.values.first?()
        #expect(
            await eventually {
                await state.workingTreeChurn == RepositoryChurn(changedFileCount: 0, added: 0, deleted: 0)
            })
        #expect(await client.numstatCalls == numstats)
    }

    @Test func theChurnFollowsEditsWhileACommitIsShown() async {
        let (h, state, client) = await showingCommit()
        await client.set(files: [changedFile("x.swift")])
        await client.set(numstat: [row("x.swift", 4, 2)], area: .unstaged)
        await client.set(numstat: [], area: .staged)

        h.watcherCallbacks.values.first?()
        #expect(
            await eventually {
                await state.workingTreeChurn == RepositoryChurn(changedFileCount: 1, added: 4, deleted: 2)
            })
    }

    /// Ticks run one at a time, so the newer read here is the one a branch switch in
    /// commit scope starts while the tick's read is in flight.
    @Test func anOlderChurnReadCannotOverwriteANewerOne() async {
        let (h, state, client) = await showingCommit()
        await client.set(numstat: [row("x.swift", 1, 0), row("y.swift", 1, 0), row("z.swift", 1, 0)], area: .unstaged)
        await client.set(numstat: [], area: .staged)
        await client.hold(true)
        await client.set(files: [changedFile("x.swift")])
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await client.heldCount == 1 })

        await client.set(files: [changedFile("x.swift"), changedFile("y.swift"), changedFile("z.swift")])
        let newer = RepositoryChurn(changedFileCount: 3, added: 3, deleted: 0)
        let switching = Task { await state.switchBranch(to: "other") }
        #expect(await eventually { await client.heldCount == 2 })

        await client.releaseLast()
        #expect(await eventually { await state.workingTreeChurn == newer })
        await client.hold(false)
        await client.releaseFirst()
        await switching.value
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.workingTreeChurn == newer, "the older read lands last and is dropped")
    }

    /// Returning to the working tree outranks a churn read still in flight, even while the
    /// new list's counts are still coming.
    @Test func aWorkingTreeRefreshOutranksAChurnReadInFlight() async {
        let (h, state, client) = await showingCommit()
        await client.hold(true)
        await client.set(files: [changedFile("x.swift")])
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await client.heldCount == 1 })

        await client.set(files: [changedFile("x.swift"), changedFile("y.swift")])
        await client.set(numstat: [row("x.swift", 1, 0), row("y.swift", 1, 0)], area: .unstaged)
        await client.set(numstat: [], area: .staged)
        await client.holdNumstat(true)
        state.selectWorkingTree()
        #expect(await eventually { await client.heldCount == 2 })
        await client.releaseLast()
        #expect(await eventually { await client.heldNumstatCount == 2 })
        let numstat = await client.numstatCalls

        await client.hold(false)
        await client.releaseFirst()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await client.numstatCalls == numstat, "the outranked read stops before numstat")
        #expect(state.workingTreeChurn == Self.churn)

        await client.releaseNumstat()
        #expect(
            await eventually {
                await state.workingTreeChurn == RepositoryChurn(changedFileCount: 2, added: 2, deleted: 0)
            })
    }

    @Test func aFailedStatusReadLeavesNoChurn() async {
        let (h, state, client) = await showingCommit()
        await client.fail(true)
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await state.workingTreeChurn == nil })

        await client.fail(false)
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await state.workingTreeChurn == Self.churn })
    }

    @Test(arguments: [(0, "No changes"), (1, "1 change"), (2, "2 changes"), (120, "120 changes")])
    func changeCountText(count: Int, text: String) {
        #expect(ChangeCountText.make(count) == text)
    }
}
