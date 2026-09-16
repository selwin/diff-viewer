import Foundation
import Testing

@testable import DiffViewer

/// The selection as a set: what the detail pane is built from, and when a refresh has to
/// build it again.
@MainActor
struct WindowStateSelectionTests {
    /// The sidebar order is unstaged then staged, so these draw as a, b, c.
    let files = [
        changedFile("a.swift"), changedFile("b.swift"), changedFile("c.swift", area: .staged),
    ]

    /// The files a published changeset covers, in the order its sections are drawn.
    private func sections(_ state: WindowState) -> [ChangedFile.ID]? {
        guard case let .changeset(document)? = state.diffLoader.content else { return nil }
        return document.sections.map(\.file.id)
    }

    /// Waits for a changeset covering exactly `expected` to finish loading.
    private func awaitChangeset(_ expected: [ChangedFile], in state: WindowState) async {
        #expect(await eventually { await self.sections(state) == expected.map(\.id) })
        #expect(await eventually { await !state.diffLoader.hasActiveWork })
    }

    // MARK: Several files

    @Test func selectingTwoFilesShowsThemAsOneChangesetInSidebarOrder() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: files)

        // Picked bottom-up, which is what a ⌘-click from the staged section does.
        state.selection = [.file(files[2].id), .file(files[0].id)]
        #expect(state.detailSelection == .files)
        await awaitChangeset([files[0], files[2]], in: state)

        // The other order is the same set, so it is also the same changeset.
        state.selection = [.file(files[0].id), .file(files[2].id)]
        await awaitChangeset([files[0], files[2]], in: state)
    }

    @Test func oneOfSeveralIsASingleFileDiffAgain() async {
        let h = Harness()
        let state = h.makeState()
        await h.adopt(state, "A", files: files)

        state.selection = [.file(files[0].id), .file(files[1].id)]
        await awaitChangeset([files[0], files[1]], in: state)

        state.selection = [.file(files[1].id)]
        #expect(state.detailSelection == .file(files[1].id))
        #expect(await eventually { await state.diffLoader.contentFileID == self.files[1].id })
        #expect(sections(state) == nil, "a single file is not a changeset")
    }

    // MARK: All changes wins

    @Test func allChangesWinsOverFileRowsAndAddingOneStartsNoLoad() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        #expect(state.selection == [.allChanges])
        await awaitChangeset(files, in: state)
        let reads = await repo.client.contentReads

        // ⌘A and a ⇧-click range from the top both land here: All changes plus rows.
        state.selection = [.allChanges, .file(files[0].id)]
        #expect(state.detailSelection == .allChanges)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await repo.client.contentReads == reads, "the pane shows the same thing, so nothing reloads")
        #expect(sections(state) == files.map(\.id))
    }

    @Test func aWatcherRefreshRebuildsAllChangesWhenASelectedRowDisappears() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        state.selection = [.allChanges, .file(files[0].id)]
        await awaitChangeset(files, in: state)
        let reads = await repo.client.contentReads

        let remaining = [files[1], files[2]]
        await repo.client.set(files: remaining)
        h.watcherCallbacks[repo.root]?()

        #expect(await eventually { await state.files.map(\.id) == remaining.map(\.id) })
        #expect(state.selection == [.allChanges], "the row that went away leaves the set; All changes does not")
        await awaitChangeset(remaining, in: state)
        #expect(await repo.client.contentReads > reads, "a shorter list is a different changeset")
    }

    // MARK: Survivors

    @Test func aRefreshKeepsTheSelectedFilesThatAreStillThere() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        state.selection = Set(files.map { DiffSelection.file($0.id) })
        await awaitChangeset(files, in: state)

        let remaining = [files[0], files[2]]
        await repo.client.set(files: remaining)
        await state.refresh()

        #expect(state.selection == [.file(files[0].id), .file(files[2].id)])
        #expect(state.detailSelection == .files)
        await awaitChangeset(remaining, in: state)
    }

    /// Pruning a selection draws a different set of rows, so change navigation has to
    /// start over: its index and scroll target address the document being replaced.
    @Test func aRefreshThatPrunesTheSelectionResetsChangeNavigation() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)
        state.selection = Set(files.map { DiffSelection.file($0.id) })
        await awaitChangeset(files, in: state)
        #expect(state.changeBlockCount > 0)

        state.nextChange()
        #expect(state.currentChangeIndex != nil)
        #expect(state.scrollTarget != nil)

        let remaining = [files[1], files[2]]
        await repo.client.set(files: remaining)
        h.watcherCallbacks[repo.root]?()

        #expect(await eventually { await state.files.map(\.id) == remaining.map(\.id) })
        #expect(state.selection == [.file(files[1].id), .file(files[2].id)])
        #expect(state.currentChangeIndex == nil)
        #expect(state.scrollTarget == nil)
    }

    // MARK: Error lifetime

    @Test func aRefreshClearsOnlyTheErrorARefreshRaised() async {
        let h = Harness()
        let state = h.makeState()
        let repo = await h.adopt(state, "A", files: files)

        await repo.client.fail(true)
        await state.refresh()
        #expect(state.errorMessage != nil)
        await repo.client.fail(false)
        await state.refresh()
        #expect(state.errorMessage == nil, "a status read that works again explains itself")

        // Standing in for a file action's failure, which no refresh has the news of.
        state.errorMessage = "could not move to Trash"
        await state.refresh()
        #expect(state.errorMessage == "could not move to Trash")
    }
}
