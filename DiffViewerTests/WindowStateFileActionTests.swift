import Foundation
import Testing

@testable import DiffViewer

@MainActor
struct WindowStateFileActionTests {
    /// The sidebar order is unstaged then staged, so these draw as a, b, c.
    let files = [
        changedFile("a.swift"), changedFile("b.swift"), changedFile("c.swift", area: .staged),
    ]

    /// Adopts `files`, then says what the repository becomes once the write lands, so the
    /// action validates against the world it clicked on and refreshes into the new one.
    private func adopt(_ h: Harness, _ state: WindowState, after: [ChangedFile]) async -> StubRepoClient {
        let repo = await h.adopt(state, "A", files: files)
        await repo.client.set(filesAfterWrite: after)
        return repo.client
    }

    @Test func stagingTheSelectedFileMovesTheSelectionWithIt() async {
        let h = Harness()
        let state = h.makeState()
        let staged = changedFile("a.swift", area: .staged)
        let client = await adopt(h, state, after: [staged, files[1], files[2]])
        state.selectedFileID = files[0].id

        await state.perform(.stage, on: files[0])

        let performed = await client.performed
        #expect(performed.map(\.action) == [.stage])
        #expect(performed.map(\.path) == ["a.swift"])
        #expect(await eventually { await state.selectedFileID == staged.id })
        #expect(state.selectedFile?.area == .staged)
        #expect(h.published.last?.cause == .fileAction)
        #expect(state.errorMessage == nil)
    }

    @Test func discardingTheSelectedFileSelectsTheRowThatTookItsPlace() async {
        let h = Harness()
        let state = h.makeState()
        let client = await adopt(h, state, after: [files[1], files[2]])
        state.selectedFileID = files[0].id
        let next = files[1].id

        await state.perform(.discard, on: files[0])

        #expect(await client.performed.map(\.action) == [.discard])
        #expect(await eventually { await state.selectedFileID == next })
        #expect(state.errorMessage == nil)
    }

    @Test func discardingTheOnlyRowLeavesNothingSelected() async {
        let h = Harness()
        let state = h.makeState()
        let only = [changedFile("a.swift")]
        let repo = await h.adopt(state, "A", files: only)
        await repo.client.set(filesAfterWrite: [])
        state.selectedFileID = only[0].id

        await state.perform(.discard, on: only[0])

        #expect(await eventually { await state.files.isEmpty })
        #expect(state.selectedFileID == nil)
        #expect(state.errorMessage == nil)
    }

    @Test func actingOnAnotherRowLeavesTheSelectionAlone() async {
        let h = Harness()
        let state = h.makeState()
        let staged = changedFile("a.swift", area: .staged)
        _ = await adopt(h, state, after: [staged, files[1], files[2]])
        state.selectedFileID = files[2].id

        await state.perform(.stage, on: files[0])

        #expect(await eventually { await h.published.last?.cause == .fileAction })
        #expect(state.selectedFileID == files[2].id)
    }

    @Test func aFailedWriteReportsGitsMessageAndChangesNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        await repo.client.fail(actions: true)
        let publishes = h.published.count

        await state.perform(.stage, on: files[0])

        #expect(state.errorMessage?.contains("index.lock exists") == true)
        #expect(state.files == files)
        #expect(h.published.count == publishes, "a failed write must not publish a file list")
    }

    /// A write is only as safe as the list it was checked against, and `status()` is that
    /// list. When the read fails there is nothing to check, so nothing runs.
    @Test func aWriteWhoseStatusReadFailsRunsNothingAndReportsTheError() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        await repo.client.fail(true)

        await state.perform(.stage, on: files[0])

        #expect(await repo.client.performed.isEmpty)
        #expect(state.errorMessage != nil)
        #expect(state.files == files)
    }

    @Test func trashingAnUntrackedFileCallsTheClientAndRepublishes() async {
        let h = Harness()
        let state = h.makeState()
        let untracked = changedFile("u.txt", kind: .untracked)
        let repo = await h.adopt(state, "A", files: [untracked])
        await repo.client.set(filesAfterWrite: [])

        await state.perform(.trash, on: untracked)

        #expect(await repo.client.trashed == ["u.txt"])
        #expect(await eventually { await h.published.last?.cause == .fileAction })
        #expect(state.files.isEmpty)
    }

    @Test func aClosedWindowPerformsNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        state.close()

        await state.perform(.stage, on: files[0])

        #expect(await repo.client.performed.isEmpty)
    }

    @Test func aFileThatLeftTheListPerformsNothing() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)

        await state.perform(.stage, on: changedFile("stale.swift"))

        #expect(await repo.client.performed.isEmpty)
    }

    /// A queued write is checked again, against a fresh status read, once the write ahead
    /// of it has finished. `ChangedFile.id` is area and path only, so the same row can
    /// come back with a new kind — and "Restore File" on a deleted row would then be an
    /// unconfirmed discard of a modified one.
    @Test func aQueuedWriteIsDroppedWhenItsRowCameBackWithAnotherKind() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        let client = repo.client
        await client.holdActions(true)

        let first = Task { await state.perform(.stage, on: files[0]) }
        #expect(await eventually { await client.heldActionCount == 1 })
        let second = Task { await state.perform(.discard, on: files[1]) }
        // Let the second write reach the queue, where it waits on the first.
        for _ in 0..<10 { await Task.yield() }
        // What the second write's status read will find: b is a deletion now, so the
        // queued discard no longer means what the menu offered.
        await client.set(files: [files[0], changedFile("b.swift", kind: .deleted), files[2]])
        await client.holdActions(false)
        await client.releaseActions()
        await first.value
        await second.value

        let performed = await client.performed
        #expect(performed.map(\.action) == [.stage])
        #expect(performed.map(\.path) == ["a.swift"])
        #expect(state.errorMessage == nil)
    }

    /// The reason the check reads status rather than `files`: a refresh publishes nothing
    /// when a newer one supersedes it, so the list on screen can still describe the world
    /// from before the write ahead of this one. Trusting it here would trash a file that
    /// is no longer untracked.
    @Test func aQueuedWriteIsDroppedEvenWhenTheEarlierRefreshWasSuperseded() async {
        let h = Harness()
        let state = h.makeState()
        let untracked = changedFile("u.txt", kind: .untracked)
        let staged = changedFile("u.txt", area: .staged, kind: .added)
        let repo = await h.adopt(state, "A", files: [untracked])
        let client = repo.client
        await client.set(filesAfterWrite: [staged])
        // Every status read from here on is held, so their order can be chosen by hand.
        await client.hold(true)
        let readsBefore = await client.statusCalls

        let first = Task { await state.perform(.stage, on: untracked) }
        let second = Task { await state.perform(.trash, on: untracked) }
        // (1) the stage's own validation read.
        #expect(await eventually { await client.statusCalls == readsBefore + 1 })
        await client.releaseFirst()
        // The stage runs, the repository becomes `[staged]`, and (2) its refresh read
        // waits.
        #expect(await eventually { await client.statusCalls == readsBefore + 2 })
        // A watcher refresh overtakes it: (3) waits behind (2) and owns the serial.
        h.watcherCallbacks[repo.root]?()
        #expect(await eventually { await client.statusCalls == readsBefore + 3 })
        await client.releaseFirst()
        await first.value
        #expect(state.files == [untracked], "the superseded refresh must publish nothing")

        // Only now does the queued trash validate, with (4), which is the last one held.
        #expect(await eventually { await client.statusCalls == readsBefore + 4 })
        await client.releaseLast()
        await second.value

        #expect(await client.trashed.isEmpty, "u.txt is tracked now; the menu's trash is stale")
        let performed = await client.performed
        #expect(performed.map(\.action) == [.stage])
        #expect(performed.map(\.path) == ["u.txt"])

        await client.releaseFirst()
        #expect(await eventually { await state.files == [staged] })
    }

    /// The write's own refresh is not always the one that publishes its result: a watcher
    /// refresh can land while `git` is still running and clear the selection, because the
    /// row's id has gone. The restoration is recorded from what was selected before the
    /// write, so the reader still lands on the file they were reading.
    @Test func aRefreshDuringTheWriteStillMovesTheSelection() async {
        let h = Harness()
        let state = h.makeState()
        let staged = changedFile("a.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[1]])
        let client = repo.client
        state.selectedFileID = files[0].id
        await client.holdActions(true)

        let write = Task { await state.perform(.stage, on: files[0]) }
        #expect(await eventually { await client.heldActionCount == 1 })
        let afterWatcher = [staged, files[1]]
        await client.set(files: afterWatcher)
        h.watcherCallbacks[repo.root]?()
        #expect(
            await eventually {
                guard await state.selectedFileID == nil else { return false }
                return await state.files == afterWatcher
            })
        await client.releaseActions()
        await write.value

        #expect(await eventually { await state.selectedFileID == staged.id })
        #expect(state.errorMessage == nil)
    }

    /// The same race, except the reader picked another row while `git` was running. That
    /// choice is newer than the write and is left alone.
    @Test func aSelectionMadeDuringTheWriteIsNotOverridden() async {
        let h = Harness()
        let state = h.makeState()
        let staged = changedFile("a.swift", area: .staged)
        let repo = await h.adopt(state, "A", files: [files[0], files[1]])
        let client = repo.client
        state.selectedFileID = files[0].id
        await client.holdActions(true)

        let write = Task { await state.perform(.stage, on: files[0]) }
        #expect(await eventually { await client.heldActionCount == 1 })
        let afterWatcher = [staged, files[1]]
        await client.set(files: afterWatcher)
        h.watcherCallbacks[repo.root]?()
        #expect(
            await eventually {
                guard await state.selectedFileID == nil else { return false }
                return await state.files == afterWatcher
            })
        state.selectedFileID = files[1].id
        await client.releaseActions()
        await write.value

        #expect(await eventually { await h.published.last?.cause == .fileAction })
        #expect(state.selectedFileID == files[1].id)
    }
}
