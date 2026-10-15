import Foundation
import Testing

@testable import DiffViewer

private let range = CommitRange(
    baseName: "main", targetName: "feature", mergeBaseSHA: objectID("base"), targetSHA: objectID("tip"))
private let rangeFiles = [changedFile("src/a.swift", area: .range(range)), changedFile("b.swift", area: .range(range))]

/// A comparison tab: a fixed range that is never watched, never left, and never written to.
@MainActor
struct WindowStateComparisonTests {
    private var listedPaths: [String] { inPublishedFileOrder(rangeFiles).map(\.path) }

    private func hasContent(_ state: WindowState, for file: ChangedFile) -> Bool {
        state.diffLoader.content != nil && state.diffLoader.contentFileID == file.id
    }

    /// Nothing but the range was read: no watcher, and no history, HEAD or stash read. The
    /// history and stash tasks are stored when started, so their absence proves neither
    /// ran; HEAD's read has no task to check, so its counter stands in.
    private func expectRangeReadsOnly(
        _ h: Harness, _ state: WindowState, _ root: RepositoryRoot, _ client: StubRepoClient
    ) async {
        #expect(h.watcherStarts[root] == nil)
        #expect(state.session?.historyTask == nil)
        #expect(state.session?.stashTask == nil)
        #expect(await client.headStateCalls == 0)
    }

    @Test func adoptingListsTheRangeAndReadsNothingElse() async {
        let h = Harness()
        let state = h.makeState()
        let (root, client) = await h.adoptComparison(state, range: range, files: rangeFiles)

        #expect(state.scope == .range(range))
        #expect(state.isComparisonTab)
        #expect(state.title == range.title)
        #expect(state.files.map(\.path) == listedPaths)
        await expectRangeReadsOnly(h, state, root, client)
    }

    /// The empty list before the first read returns is not "No differences".
    @Test func theFirstReadShowsAsLoading() async {
        let h = Harness()
        let state = h.makeState()
        let (root, client) = h.repo("A", files: [])
        await client.set(rangeFiles: rangeFiles)
        await client.hold(.rangeFiles)
        #expect(state.adopt(root: root, client: client, comparing: range))
        #expect(await eventually { await client.heldCount(.rangeFiles) == 1 })
        #expect(state.isLoadingScope)

        await client.hold(.rangeFiles, false)
        await client.release(.rangeFiles)
        #expect(await eventually { await !state.isLoadingScope })
        #expect(state.files.map(\.path) == listedPaths)
    }

    @Test func theScopeCannotLeaveTheRange() async {
        let h = Harness()
        let state = h.makeState()
        await h.adoptComparison(state, range: range, files: rangeFiles)

        state.selectWorkingTree()
        state.select(commit: commitSummary("c1"))
        #expect(state.scope == .range(range))
        #expect(state.files.map(\.path) == listedPaths)
    }

    /// Only writes that nothing else would stop: merge, pull, push, publish and delete
    /// already need a branch read, which a comparison never makes.
    @Test func repositoryWritesAreRefused() async {
        let h = Harness()
        let state = h.makeState()
        let (_, client) = await h.adoptComparison(state, range: range, files: rangeFiles)
        let entry = StashEntry(
            stashIndex: 0, sha: objectID("stash0"), shortSha: "s0", parents: [objectID("base"), objectID("index0")],
            committedAt: Date(timeIntervalSince1970: 1_789_300_000), author: "Tester", message: "WIP",
            sourceBranch: "main", hasDefaultMessage: false, churn: nil)

        await state.switchBranch(to: "feature")
        await state.createBranch(named: "topic")
        await state.checkoutRemoteBranch(remoteBranch("feature", remote: "origin"))
        await state.fetchAllRemotes()
        await state.popStash(entry)
        await state.dropStash(entry)

        #expect(await client.switchBranchCalls.isEmpty)
        #expect(await client.createBranchCalls.isEmpty)
        #expect(await client.checkoutTrackingCalls.isEmpty)
        #expect(await client.remoteNamesCalls == 0)
        #expect(await client.popCalls.isEmpty)
        #expect(await client.dropCalls.isEmpty)
    }

    @Test func noPickerOrSheetOpens() async {
        let h = Harness()
        let state = h.makeState()
        await h.adoptComparison(state, range: range, files: rangeFiles)

        #expect(!state.canOpenBranchPicker)
        #expect(!state.canOpenNewBranchSheet)
        #expect(!state.canOpenMergeSheet)
        #expect(!state.canOpenCommitPicker)
        #expect(!state.canOpenStashPicker)
        #expect(state.stashActionsBlockedReason == "Comparisons are read-only")
    }

    @Test func aFailedReadKeepsTheRange() async {
        let h = Harness()
        let state = h.makeState()
        await h.adoptComparison(state, range: range, files: rangeFiles) { await $0.fail(rangeFiles: true) }

        #expect(state.scope == .range(range))
        #expect(state.listReadFailed)
        #expect(state.errorMessage != nil)
        #expect(state.files.isEmpty)
    }

    /// ⌘R and the sidebar's Retry re-read only the range, after a failed first read or a
    /// failed re-read that left the earlier rows up.
    @Test func retryListsTheRangeAgain() async {
        let h = Harness()
        let state = h.makeState()
        let (root, client) = await h.adoptComparison(state, range: range, files: rangeFiles) {
            await $0.fail(rangeFiles: true)
        }

        await client.fail(rangeFiles: false)
        await state.refresh()
        #expect(state.files.map(\.path) == listedPaths)
        #expect(!state.listReadFailed)

        await client.fail(rangeFiles: true)
        await state.refresh()
        #expect(state.listReadFailed)
        #expect(state.files.map(\.path) == listedPaths, "the earlier rows stay, marked failed")

        await client.fail(rangeFiles: false)
        await state.refresh()
        #expect(!state.listReadFailed)
        #expect(state.scope == .range(range))
        await expectRangeReadsOnly(h, state, root, client)
    }
    /// No rescan follows showing a comparison, so showing reloads the owed diff itself.
    @Test func showingAgainFinishesALoadCancelledByHiding() async {
        let h = Harness()
        let state = h.makeState()
        let (root, client) = await h.adoptComparison(state, range: range, files: rangeFiles)
        let file = rangeFiles[0]

        // A whitespace setting the All changes load did not use, so the file is not reused from it.
        h.preferences.hideWhitespace.toggle()
        await client.hold(.revisionReads)
        state.selection = [.file(file.id)]
        #expect(await eventually { await client.heldCount(.revisionReads) >= 1 })

        state.isVisible = false
        #expect(state.diffStale)
        await client.hold(.revisionReads, false)
        await client.release(.revisionReads)

        state.isVisible = true
        #expect(await eventually { await !state.diffStale })
        #expect(await eventually { await self.hasContent(state, for: file) })
        #expect(h.watcherStarts[root] == nil)
    }
}
