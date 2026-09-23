import Foundation
import Testing

@testable import DiffViewer

/// Holds every search until the test releases it. Releasing calls one at a time lets the
/// test choose the completion order.
@MainActor
final class SearchGate {
    private struct Pending {
        let call: Int
        let key: FindKey
        let displayed: DisplayedDocument
        let continuation: CheckedContinuation<FindResults, any Error>
    }

    /// Every search that reached the gate, in order.
    private(set) var calls: [FindKey] = []
    private var pending: [Pending] = []

    func search(_ key: FindKey, _ displayed: DisplayedDocument) async throws -> FindResults {
        let call = calls.count
        calls.append(key)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(call: call, key: key, displayed: displayed, continuation: continuation))
        }
    }

    /// Completes every held search with real results, obsolete ones included.
    func release() {
        let held = pending
        pending = []
        held.forEach(Self.complete)
    }

    /// Completes only the held search at `index` in `calls`.
    func release(call index: Int) {
        guard let position = pending.firstIndex(where: { $0.call == index }) else { return }
        Self.complete(pending.remove(at: position))
    }

    private static func complete(_ entry: Pending) {
        entry.continuation.resume(with: Result { try DiffFinder.results(for: entry.key, in: entry.displayed) })
    }
}

@MainActor
struct FindStateTests {
    let content = UUID()

    private func makeFind() -> (FindState, SearchGate) {
        let gate = SearchGate()
        let find = FindState { key, displayed in try await gate.search(key, displayed) }
        return (find, gate)
    }

    /// Equal rows, the same text on both sides unless `old` is given. `shown` is the
    /// projection: the document rows left unfolded.
    private func displayed(
        _ new: [String], old: [String]? = nil, content: UUID, projection: UUID = UUID(), shown: [Int]? = nil
    ) -> DisplayedDocument {
        let old = old ?? new
        let rows = new.indices.map { DiffRow.equal(old: $0, new: $0) }
        let document = DiffDocument(oldLines: old, newLines: new, rows: rows, language: nil)
        let displayRows = (shown ?? Array(rows.indices)).map { DisplayRow.documentRow($0) }
        return DisplayedDocument(
            document: document, displayRows: displayRows, contentID: content, projectionID: projection)
    }

    /// Waits until the gate has seen `count` searches in total.
    private func waitForSearch(_ gate: SearchGate, count: Int) async {
        #expect(await eventually { await gate.calls.count >= count })
    }

    /// Waits for the next search, releases it, and waits for its results to be published.
    private func complete(_ find: FindState, _ gate: SearchGate) async {
        await waitForSearch(gate, count: gate.calls.count + 1)
        let before = find.results?.id
        gate.release()
        #expect(await eventually { @MainActor in find.results?.id != before && find.isCurrent })
    }

    /// Presented over a document holding "foo" on the given rows of `count`.
    private func open(fooAt rows: Set<Int>, count: Int = 8) -> (FindState, SearchGate, DisplayedDocument) {
        let (find, gate) = makeFind()
        let doc = displayed((0..<count).map { rows.contains($0) ? "foo \($0)" : "bar \($0)" }, content: content)
        find.present()
        find.update(displayed: doc)
        return (find, gate, doc)
    }

    // MARK: Scheduling

    @Test func quickTypingRunsOneSearchForTheLastQuery() async {
        let (find, gate, _) = open(fooAt: [1, 3])
        find.query = "f"
        find.query = "fo"
        find.query = "foo"
        await complete(find, gate)
        #expect(gate.calls.map(\.query) == ["foo"])
        #expect(find.currentIndex == 0)
        #expect(find.activeReveal != nil)
        #expect(find.activeReveal?.key == find.results?.key)
        #expect(find.activeReveal?.match.documentRow == 1)
    }

    @Test func documentUpdateDuringDebounceStillSelectsFirstMatch() async {
        let (find, gate, doc) = open(fooAt: [2, 5])
        find.query = "foo"
        find.update(displayed: displayed(doc.document.newLines, content: content))
        await complete(find, gate)
        #expect(gate.calls.count == 1)
        #expect(find.currentIndex == 0)
        #expect(find.activeReveal?.match.documentRow == 2)
    }

    @Test func firstMatchIntentSurvivesAnEmptyPublication() async {
        let (find, gate, _) = open(fooAt: [])
        find.query = "foo"
        await complete(find, gate)
        #expect(find.results?.matches.isEmpty == true)
        #expect(find.currentIndex == nil)
        #expect(find.reveal == nil)

        find.update(displayed: displayed(["bar", "foo", "foo"], content: content))
        await complete(find, gate)
        #expect(find.currentIndex == 0)
        #expect(find.activeReveal?.match.documentRow == 1)
    }

    @Test func freshQueryLandsOnFirstMatchInView() async {
        func land(visible: Range<Int>, reportedFor contentID: UUID) async -> Int? {
            let (find, gate, _) = open(fooAt: [1, 3, 5])
            find.noteVisibleRows(visible, contentID: contentID)
            find.query = "foo"
            await complete(find, gate)
            #expect(find.activeReveal?.match == find.currentMatch)
            return find.currentIndex
        }
        #expect(await land(visible: 4..<8, reportedFor: content) == 2)
        #expect(await land(visible: 6..<8, reportedFor: content) == 0, "every match above the viewport wraps")
        #expect(await land(visible: 4..<8, reportedFor: UUID()) == 0, "rows from other content are ignored")
    }

    // MARK: Carrying the selection

    @Test func sameContentWithFewerMatchesCarriesTheOccurrence() async {
        let (find, gate, doc) = open(fooAt: [0, 2, 4])
        find.query = "foo"
        await complete(find, gate)
        find.next()
        let stepped = find.reveal?.id
        #expect(find.currentMatch?.documentRow == 2)

        // A fold hides row 0: the same occurrence moves to index 0.
        find.update(displayed: displayed(doc.document.newLines, content: content, shown: [1, 2, 3, 4, 5]))
        await complete(find, gate)
        #expect(find.currentIndex == 0)
        #expect(find.currentMatch?.documentRow == 2)

        // Row 2 goes too: the index is kept, clamped to what remains.
        find.update(displayed: displayed(doc.document.newLines, content: content, shown: [4, 5]))
        await complete(find, gate)
        #expect(find.currentIndex == 0)
        #expect(find.currentMatch?.documentRow == 4)
        #expect(find.reveal?.id == stepped, "carrying never reveals")
        #expect(find.activeReveal == nil)
    }

    @Test func replacingTheDocumentStartsOverAtTheFirstMatch() async {
        let (find, gate, _) = open(fooAt: [0, 2, 4])
        find.query = "foo"
        await complete(find, gate)
        find.next()
        find.next()
        let stepped = find.reveal?.id

        let other = UUID()
        find.update(displayed: displayed(["bar", "bar", "bar", "foo"], content: other))
        #expect(find.currentIndex == nil)
        #expect(find.reveal == nil)
        await complete(find, gate)
        #expect(find.currentIndex == 0)
        #expect(find.currentMatch?.documentRow == 3)
        #expect(find.activeReveal?.key.contentID == other)
        #expect(find.reveal?.id != stepped)
    }

    @Test func foldHidingEveryMatchKeepsTheOccurrenceForLater() async {
        let (find, gate, doc) = open(fooAt: [0, 2])
        find.query = "foo"
        await complete(find, gate)
        find.next()
        let stepped = find.reveal?.id

        find.update(displayed: displayed(doc.document.newLines, content: content, shown: [1, 3]))
        await complete(find, gate)
        #expect(find.currentIndex == nil)
        #expect(find.presentation != nil)
        #expect(find.presentation?.currentIndex == nil)
        #expect(find.counterText == "Not found")

        find.update(displayed: displayed(doc.document.newLines, content: content))
        await complete(find, gate)
        #expect(find.currentIndex == 1)
        #expect(find.currentMatch?.documentRow == 2)
        #expect(find.reveal?.id == stepped, "restoring never reveals")
    }

    // MARK: Reader input

    @Test func clickDuringSearchIsHonoured() async {
        let (find, gate, _) = open(fooAt: [1, 3])
        find.query = "foo"
        await waitForSearch(gate, count: 1)
        find.notePaneInteraction(.new)
        gate.release()
        #expect(await eventually { await find.isCurrent })
        #expect(find.currentIndex == nil)
        #expect(find.reveal == nil)
        #expect(find.counterText == "2 matches")
    }

    @Test func pickerRevealsButPaneClickDoesNot() async {
        let (find, gate) = makeFind()
        find.present()
        find.update(
            displayed: displayed(["x", "foo c", "y"], old: ["foo a", "x", "foo b"], content: content))
        find.query = "foo"
        await complete(find, gate)
        #expect(find.activeReveal?.key.side == .new)

        find.selectSide(.old)
        #expect(find.side == .old)
        #expect(find.presentation == nil)
        #expect(find.reveal == nil)
        await complete(find, gate)
        #expect(find.currentIndex == 0)
        #expect(find.activeReveal?.key.side == .old)
        #expect(find.activeReveal?.match.documentRow == 0)

        find.notePaneInteraction(.new)
        #expect(find.side == .new)
        await complete(find, gate)
        #expect(find.results?.key.side == .new)
        #expect(find.currentIndex == nil)
        #expect(find.reveal == nil)
    }

    @Test func steppingWaitsForTheNewSidesResults() async {
        let (find, gate) = makeFind()
        find.present()
        find.update(displayed: displayed(["foo", "foo"], old: ["foo", "bar"], content: content))
        find.query = "foo"
        await complete(find, gate)

        find.selectSide(.old)
        #expect(!find.canStep)
        find.next()
        #expect(find.reveal == nil)
        #expect(find.currentIndex == 0)
        await complete(find, gate)
        #expect(find.canStep)
        #expect(find.activeReveal?.key.side == .old)
    }

    @Test func changingTheQueryHidesTheStepsReveal() async {
        let (find, gate, _) = open(fooAt: [0, 2])
        find.query = "foo"
        await complete(find, gate)
        find.next()
        let stepped = find.reveal?.id
        #expect(find.activeReveal != nil)

        find.query = "bar"
        #expect(find.activeReveal == nil)
        await complete(find, gate)
        #expect(find.activeReveal != nil)
        #expect(find.reveal?.id != stepped)
    }

    @Test func projectionChangeInvalidatesSteppingAtOnce() async {
        let (find, gate, doc) = open(fooAt: [0, 2])
        find.query = "foo"
        await complete(find, gate)
        #expect(find.canStep)
        #expect(find.counterText == "1 of 2")

        find.update(displayed: displayed(doc.document.newLines, content: content))
        #expect(!find.canStep)
        #expect(find.counterText.isEmpty)
        #expect(find.presentation != nil, "fills survive until the replacement arrives")
        await complete(find, gate)
        #expect(find.canStep)
    }

    @Test func reopeningAfterAPaneClickSelectsAgain() async {
        let (find, gate, _) = open(fooAt: [1, 3])
        find.query = "foo"
        await complete(find, gate)
        let first = find.reveal?.id

        find.dismiss()
        find.notePaneInteraction(.new)
        find.present()
        await complete(find, gate)
        #expect(find.currentIndex == 0)
        #expect(find.reveal != nil)
        #expect(find.reveal?.id != first)

        let focus = find.focusRequest
        let calls = gate.calls.count
        let reveal = find.reveal?.id
        find.present()
        #expect(find.focusRequest == focus + 1)
        #expect(gate.calls.count == calls)
        #expect(find.reveal?.id == reveal)
    }

    // MARK: Availability and focus

    @Test func contentUnavailableDropsPendingWork() async {
        let (find, gate, _) = open(fooAt: [1])
        find.query = "foo"
        await waitForSearch(gate, count: 1)
        let task = find.task
        find.contentUnavailable()
        gate.release()
        await task?.value
        #expect(find.results == nil)
        #expect(find.intent == .firstMatch)
        #expect(!find.canStep)
        #expect(find.query == "foo")
    }

    @Test func closingTheWindowCancelsTheSearch() async throws {
        let h = Harness()
        let state = h.makeState()
        let files = [changedFile("a1.swift")]
        _ = await h.adopt(state, "A", files: files)
        state.selection = [.file(files[0].id)]
        #expect(await eventually { @MainActor in !state.diffLoader.hasActiveWork && state.isFindAvailable })
        let text = try #require(state.currentContentID)
        state.reportDisplayed(displayed(["foo"], content: text))
        state.showFindBar()
        state.find.query = "foo"
        let task = try #require(state.find.task)

        state.close()
        #expect(task.isCancelled)
        await task.value
        #expect(state.find.results == nil)
        #expect(!state.find.canStep)
    }

    @Test func windowDropsStaleAndErroredReports() async throws {
        let h = Harness()
        let state = h.makeState()
        let files = [changedFile("a1.swift")]
        let repo = await h.adopt(state, "A", files: files)
        let rows = displayed(["foo"], content: UUID())

        state.reportDisplayed(rows)
        #expect(state.find.displayedIdentity == nil, "a report for other content is dropped")
        let changeset = try #require(state.currentContentID)
        state.reportDisplayed(displayed(["foo"], content: changeset))
        #expect(state.find.displayedIdentity?.contentID == changeset)

        state.selection = [.file(files[0].id)]
        #expect(await eventually { @MainActor in !state.diffLoader.hasActiveWork && state.isFindAvailable })
        let text = try #require(state.currentContentID)
        state.reportDisplayed(displayed(["foo"], content: text))
        #expect(state.find.displayedIdentity?.contentID == text)
        await repo.client.fail(worktree: ["a1.swift"])
        await state.refresh()
        #expect(await eventually { await state.diffLoader.errorMessage != nil })
        #expect(state.find.displayedIdentity == nil, "an error makes the content unavailable")
        state.reportDisplayed(displayed(["foo"], content: state.currentContentID ?? UUID()))
        #expect(state.find.displayedIdentity == nil)
        state.showFindBar()
        #expect(!state.find.isPresented)
    }

    @Test func dismissRequestsPaneFocusUntilAcknowledged() async throws {
        let (find, gate, _) = open(fooAt: [1])
        find.query = "foo"
        await complete(find, gate)

        find.dismiss()
        #expect(find.results == nil)
        #expect(find.query == "foo")
        let request = try #require(find.paneFocusRequest)
        #expect(request.side == .new)
        find.acknowledgePaneFocus(id: UUID())
        #expect(find.paneFocusRequest == request)
        find.acknowledgePaneFocus(id: request.id)
        #expect(find.paneFocusRequest == nil)

        find.dismiss()
        find.present()
        #expect(find.paneFocusRequest == nil)

        find.dismiss()
        find.update(displayed: displayed(["foo"], content: UUID()))
        #expect(find.paneFocusRequest == nil)
    }

    @Test func anOlderSearchForTheSameKeyNeverPublishesLate() async throws {
        let (find, gate, _) = open(fooAt: [1, 3])
        find.query = "foo"
        await waitForSearch(gate, count: 1)
        let firstTask = find.task
        find.query = "bar"
        find.query = "foo"
        // The "bar" search may be cancelled during its debounce or reach the gate first.
        #expect(await eventually { await gate.calls.dropFirst().contains { $0.query == "foo" } })
        let newest = try #require(gate.calls.lastIndex { $0.query == "foo" })
        #expect(newest > 0)

        gate.release(call: newest)
        #expect(await eventually { await find.isCurrent })
        #expect(find.currentIndex == 0)
        let resultsID = find.results?.id
        let revealID = find.reveal?.id
        #expect(revealID != nil)

        // Both calls share the key, so only the generation keeps the first one out.
        gate.release(call: 0)
        await firstTask?.value
        #expect(find.results?.id == resultsID)
        #expect(find.currentIndex == 0)
        #expect(find.reveal?.id == revealID)
        gate.release()
    }

    @Test func returningToAQueryRestoresItsResults() async {
        let (find, gate, _) = open(fooAt: [1, 3])
        find.query = "foo"
        await complete(find, gate)
        let fooResults = find.results?.id

        find.query = "bar"
        await waitForSearch(gate, count: 2)
        #expect(find.presentation == nil)
        find.query = "foo"
        #expect(find.isCurrent)
        #expect(find.presentation?.results.id == fooResults)

        await waitForSearch(gate, count: 3)
        gate.release()
        #expect(await eventually { await find.results?.id != fooResults })
        #expect(find.results?.key.query == "foo")
        #expect(find.presentation?.results.key.query == "foo")
        #expect(find.currentIndex == 0)
    }
}
