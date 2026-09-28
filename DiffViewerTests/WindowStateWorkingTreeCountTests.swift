import Foundation
import Testing

@testable import DiffViewer

/// The Working Tree count the commit picker shows while a commit is displayed.
@MainActor
struct WindowStateWorkingTreeCountTests {
    private let workingFiles = [changedFile("a.swift"), changedFile("a.swift", area: .staged), changedFile("b.swift")]
    private let commit = commitSummary("c1")

    /// A window showing `commit`, with the working tree's first count already published.
    private func showingCommit() async -> (h: Harness, state: WindowState, client: StubRepoClient) {
        let h = Harness()
        let state = h.makeState()
        let repo = h.repo("A", files: workingFiles)
        await repo.client.set(head: commit.ref.sha)
        await repo.client.set(commits: [commit])
        #expect(state.adopt(root: repo.root, client: repo.client))
        #expect(await eventually { await state.workingTreeChangeCount == 2 }, "a file staged and unstaged counts once")
        state.select(commit: commit)
        #expect(await eventually { await h.published.last?.cause == .scope })
        return (h, state, repo.client)
    }

    @Test func theCountFollowsEditsOnlyWhileThePickerIsOpen() async {
        let (h, state, client) = await showingCommit()
        await client.set(files: [changedFile("x.swift")])
        let reads = await client.statusCalls

        h.watcherCallbacks.values.first?()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await client.statusCalls == reads, "a closed picker reads nothing")
        #expect(state.workingTreeChangeCount == 2)

        state.isCommitPickerPresented = true
        #expect(await eventually { await state.workingTreeChangeCount == 1 })

        await client.set(files: [changedFile("x.swift"), changedFile("y.swift"), changedFile("z.swift")])
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await state.workingTreeChangeCount == 3 })
    }

    @Test func anOlderCountReadCannotOverwriteANewerOne() async {
        let (h, state, client) = await showingCommit()
        await client.hold(true)
        await client.set(files: [changedFile("x.swift")])
        state.isCommitPickerPresented = true
        #expect(await eventually { await client.heldCount == 1 })

        await client.set(files: [changedFile("x.swift"), changedFile("y.swift"), changedFile("z.swift")])
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await client.heldCount == 2 })

        await client.releaseLast()
        #expect(await eventually { await state.workingTreeChangeCount == 3 })
        await client.releaseFirst()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.workingTreeChangeCount == 3, "the older read lands last and is dropped")
    }

    /// Returning to the working tree outranks a count read still in flight.
    @Test func aWorkingTreeRefreshOutranksACountReadInFlight() async {
        let (_, state, client) = await showingCommit()
        await client.hold(true)
        await client.set(files: [changedFile("x.swift")])
        state.isCommitPickerPresented = true
        #expect(await eventually { await client.heldCount == 1 })

        state.isCommitPickerPresented = false
        await client.set(files: [changedFile("x.swift"), changedFile("y.swift")])
        state.selectWorkingTree()
        #expect(await eventually { await client.heldCount == 2 })
        await client.releaseLast()
        #expect(await eventually { await state.workingTreeChangeCount == 2 })
        await client.releaseFirst()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.workingTreeChangeCount == 2)
    }

    @Test func aFailedReadLeavesNoCount() async {
        let (h, state, client) = await showingCommit()
        let reads = await client.statusCalls
        state.isCommitPickerPresented = true
        #expect(await eventually { await client.statusCalls > reads })

        await client.fail(true)
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await state.workingTreeChangeCount == nil })

        await client.fail(false)
        h.watcherCallbacks.values.first?()
        #expect(await eventually { await state.workingTreeChangeCount == 2 })
    }

    @Test func aFailedWorkingTreeRefreshLeavesNoCount() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: workingFiles)
        #expect(state.workingTreeChangeCount == 2)

        await repo.client.fail(true)
        await state.refresh()
        #expect(state.workingTreeChangeCount == nil)
    }

    @Test(arguments: [(0, "No changes"), (1, "1 change"), (2, "2 changes"), (120, "120 changes")])
    func changeCountText(count: Int, text: String) {
        #expect(ChangeCountText.make(count) == text)
    }
}
