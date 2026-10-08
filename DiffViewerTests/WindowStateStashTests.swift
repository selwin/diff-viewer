import Foundation
import Testing

@testable import DiffViewer

/// How a window reads and publishes the stash list, and what choosing a stash does.
@MainActor
struct WindowStateStashTests {
    private func stash(_ index: Int, _ message: String) -> StashEntry {
        StashEntry(
            stashIndex: index, sha: objectID("stash\(index)\(message)"), shortSha: "s\(index)",
            parents: [objectID("base"), objectID("index\(index)")],
            committedAt: Date(timeIntervalSince1970: 1_789_300_000), author: "Tester", message: message,
            sourceBranch: "main", hasDefaultMessage: false, churn: .init(additions: 1, deletions: 0))
    }

    /// Adopts a repository whose first stash read returns `stashes`, and waits for it.
    private func adopt(_ h: Harness, _ state: WindowState, stashes: [StashEntry]) async throws -> Window {
        let repo = await h.adopt(state, "A", files: [changedFile("a.swift")]) { await $0.set(stashes: stashes) }
        try #require(await eventually { await state.stashList.readStatus == .loaded })
        return (h, state, repo.client, repo.root)
    }

    @Test func aRefsTickRereadsTheStashes() async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(h, state, stashes: [stash(0, "first")])
        #expect(state.stashList.entries.map(\.message) == ["first"])

        await w.client.set(stashes: [stash(0, "second"), stash(1, "first")])
        h.tick(w.root, [.refs])

        #expect(await eventually { await state.stashList.entries.map(\.message) == ["second", "first"] })
    }

    /// The newest request wins, whether the older read finishes with a list or an error.
    @Test(arguments: [false, true])
    func anOlderReadNeverOverwritesANewerOne(olderFails: Bool) async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(h, state, stashes: [])
        await w.client.set(stashes: [stash(0, "old")])
        await w.client.fail(stashes: olderFails)
        await w.client.hold(.stashes)
        h.tick(w.root, [.refs])
        try #require(await eventually { await w.client.heldCount(.stashes) == 1 })
        let older = try #require(state.session?.stashTask)

        await w.client.set(stashes: [stash(0, "new")])
        await w.client.fail(stashes: false)
        h.tick(w.root, [.refs])
        try #require(await eventually { await w.client.heldCount(.stashes) == 2 })
        await w.client.releaseLast(.stashes)
        try #require(await eventually { await state.stashList.entries.map(\.message) == ["new"] })

        await w.client.release(.stashes)
        await older.value

        #expect(state.stashList.entries.map(\.message) == ["new"])
        #expect(state.stashList.readStatus == .loaded)
    }

    @Test func aClosedWindowPublishesNoStashes() async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(h, state, stashes: [stash(0, "kept")])
        await w.client.set(stashes: [stash(0, "late")])
        await w.client.hold(.stashes)
        h.tick(w.root, [.refs])
        try #require(await eventually { await w.client.heldCount(.stashes) == 1 })
        let read = try #require(state.session?.stashTask)

        state.close()
        await w.client.release(.stashes)
        await read.value

        #expect(state.stashList.entries.map(\.message) == ["kept"])
    }

    @Test func aFailedReadKeepsTheLastListAndMarksItFailed() async throws {
        let h = Harness()
        let state = h.makeState()
        let w = try await adopt(h, state, stashes: [stash(0, "kept")])

        await w.client.fail(stashes: true)
        h.tick(w.root, [.refs])

        #expect(await eventually { await state.stashList.readStatus == .failed })
        #expect(state.stashList.entries.map(\.message) == ["kept"])
    }

    @Test func choosingAStashShowsItAsACommitAndClosesThePicker() async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "picked")
        _ = try await adopt(h, state, stashes: [entry])
        state.isStashPickerPresented = true

        state.selectStash(entry)

        #expect(!state.isStashPickerPresented)
        guard case let .commit(ref) = state.scope else {
            Issue.record("expected a commit scope, got \(state.scope)")
            return
        }
        #expect(ref.sha == entry.sha)
        #expect(ref.firstParentSHA == objectID("base"))
    }

    /// Choosing a summary of the shown commit refreshes its label, such as a longer abbreviation.
    @Test func choosingTheShownStashAgainTakesItsFreshSummary() async throws {
        let h = Harness()
        let state = h.makeState()
        let entry = stash(0, "same")
        let longer = StashEntry(
            stashIndex: 0, sha: entry.sha, shortSha: entry.shortSha + "a", parents: entry.parents,
            committedAt: entry.committedAt, author: entry.author, message: entry.message, sourceBranch: nil,
            hasDefaultMessage: false, churn: entry.churn)
        _ = try await adopt(h, state, stashes: [entry])
        state.selectStash(entry)

        state.selectStash(longer)

        #expect(state.selectedCommit?.ref.shortSha == longer.shortSha)
    }

    /// Two stashes can share a commit; choosing the other one relabels the scope.
    @Test func choosingADuplicateStashShowsItsOwnMessage() async throws {
        let h = Harness()
        let state = h.makeState()
        let first = stash(0, "first")
        let second = StashEntry(
            stashIndex: 1, sha: first.sha, shortSha: first.shortSha, parents: first.parents,
            committedAt: first.committedAt, author: first.author, message: "second", sourceBranch: nil,
            hasDefaultMessage: false, churn: first.churn)
        _ = try await adopt(h, state, stashes: [first, second])
        state.selectStash(first)

        state.selectStash(second)

        #expect(state.scopeDisplayTitle == "second")
    }
}
