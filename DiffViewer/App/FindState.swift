import Foundation
import Observation

/// What the bar's status text shows. `index` is zero-based.
enum FindStatus: Equatable {
    case empty
    case noResults
    case position(index: Int, of: Int)
    case count(Int)
}

/// One window's find bar: the query, the side searched, the latest results, and which
/// match is current. One search answers both sides, so switching side never re-searches.
///
/// Results, the current selection, and the selection intent are separate. A search never
/// decides what to select when it starts; it resolves the intent that is live when it
/// completes. Everything reaching the panes is validated against the live key first, and
/// every change of intent clears what the previous intent had queued.
@MainActor
@Observable
final class FindState {
    typealias Search = @Sendable (FindKey, DisplayedDocument) async throws -> FindResults

    /// What the selection should be when a current search completes. Resolved at completion,
    /// never captured at scheduling time, so a click during a search is honoured.
    enum SelectionIntent: Equatable {
        /// Select and reveal the first match once one exists. Stays pending through empty
        /// publications (an early All changes revision may hold no match yet).
        case firstMatch
        /// Keep this occurrence selected; fall back to the clamped index if it is gone. Never
        /// scrolls. When no match remains (a fold hid them all) the occurrence is kept as the
        /// anchor to restore on a later expansion, with `currentIndex` nil meanwhile.
        case keep(occurrence: FindMatch, index: Int)
        /// The reader clicked or selected in a pane. Nothing automatic touches the selection
        /// until the next step, query, side change, or reopening of the bar.
        case none
    }

    /// Long enough to coalesce typing, short enough to feel immediate.
    static let debounce = Duration.milliseconds(80)

    private(set) var isPresented = false
    /// Kept on dismiss, so reopening searches for the same text.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            reveal = nil
            intent = .firstMatch
            schedule()
        }
    }
    private(set) var side: DocumentSide = .new
    private(set) var results: FindResults?
    private(set) var currentIndex: Int?
    /// Bumped whenever the bar's field should take focus.
    private(set) var focusRequest = 0
    private(set) var reveal: FindReveal?
    /// Set on dismiss so the pane on the searched side takes focus back.
    private(set) var paneFocusRequest: PaneFocusRequest?
    /// Observed so a projection change invalidates the counter and step buttons at once,
    /// before the re-search finishes. The snapshot itself stays out of observation.
    private(set) var displayedIdentity: (contentID: UUID, projectionID: UUID)?

    @ObservationIgnored private(set) var intent: SelectionIntent = .firstMatch
    @ObservationIgnored private var displayed: DisplayedDocument?
    /// Reported on every scroll; ignored so a scroll never invalidates SwiftUI.
    @ObservationIgnored private var visibleRows: (contentID: UUID, rows: Range<Int>)?
    /// Readable so tests can await a search's publication.
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Kept across dismiss, so reopening with an unchanged query searches without the
    /// typing debounce.
    @ObservationIgnored private var lastScheduledQuery: String?
    @ObservationIgnored private let search: Search

    init(search: @escaping Search = FindState.searchInBackground) {
        self.search = search
    }

    // MARK: Derived

    /// The key a search started now would carry; nil without a document or a query.
    var liveKey: FindKey? {
        guard !query.isEmpty, let displayedIdentity else { return nil }
        return FindKey(
            query: query, contentID: displayedIdentity.contentID, projectionID: displayedIdentity.projectionID)
    }

    /// The results answer exactly what is shown and asked now.
    var isCurrent: Bool {
        guard let results, let liveKey else { return false }
        return results.key == liveKey
    }

    var canStep: Bool { isCurrent && results?.side(side).matches.isEmpty == false }

    var currentMatch: FindMatch? {
        guard isCurrent, let matches = results?.side(side).matches, let currentIndex,
            matches.indices.contains(currentIndex)
        else { return nil }
        return matches[currentIndex]
    }

    /// Results for what is asked now, possibly from an older projection; nil for another
    /// query or content. Counts and fills use these, so they hold steady across a refold.
    private var lastKnownResults: FindResults? {
        guard let results, let liveKey, results.key.query == liveKey.query,
            results.key.contentID == liveKey.contentID
        else { return nil }
        return results
    }

    /// Fills for the panes. The projection id may lag, so fills survive a fold change until
    /// the replacement arrives; a different query or content hides them at once.
    var presentation: FindPresentation? {
        guard let results = lastKnownResults else { return nil }
        let index = currentIndex.flatMap { results.side(side).matches.indices.contains($0) ? $0 : nil }
        return FindPresentation(results: results, currentIndex: index, side: side)
    }

    /// The pending reveal, only while it was stepped under the live key and side.
    var activeReveal: FindReveal? {
        guard let reveal, reveal.key == liveKey, reveal.side == side else { return nil }
        return reveal
    }

    /// The last known match count on `documentSide`; nil before any result for the live
    /// query and content has arrived.
    func displayCount(for documentSide: DocumentSide) -> Int? {
        lastKnownResults?.side(documentSide).matches.count
    }

    /// Follows the searched side's count. A lagging projection shows the count alone: a
    /// refold can expose matches, so neither a position nor "No results" is claimed yet.
    var status: FindStatus {
        guard !query.isEmpty, let count = displayCount(for: side) else { return .empty }
        guard isCurrent else { return .count(count) }
        if count == 0 { return .noResults }
        if currentMatch != nil, let currentIndex { return .position(index: currentIndex, of: count) }
        return .count(count)
    }

    // MARK: Inputs

    func present(side newSide: DocumentSide) {
        focusRequest += 1
        guard !isPresented else { return }
        isPresented = true
        paneFocusRequest = nil
        side = newSide
        intent = .firstMatch
        schedule()
    }

    /// Query and side stay for the next opening.
    func dismiss() {
        isPresented = false
        cancel()
        results = nil
        currentIndex = nil
        reveal = nil
        intent = .firstMatch
        paneFocusRequest = PaneFocusRequest(side: side)
    }

    /// The scope control. The results already hold both sides, so this only selects; results
    /// for another projection leave the intent to the pending search's publication.
    func selectSide(_ newSide: DocumentSide) {
        guard newSide != side else { return }
        side = newSide
        currentIndex = nil
        reveal = nil
        intent = .firstMatch
        if isCurrent, let results { resolveIntent(with: results) }
    }

    /// A click or selection in a pane: the reader has taken over the selection. The side stays.
    func notePaneInteraction() {
        currentIndex = nil
        reveal = nil
        intent = .none
    }

    /// What the panes now show.
    func update(displayed newDisplayed: DisplayedDocument) {
        if let displayedIdentity, displayedIdentity.contentID == newDisplayed.contentID,
            displayedIdentity.projectionID == newDisplayed.projectionID
        {
            return
        }
        if newDisplayed.contentID != displayedIdentity?.contentID {
            // A same-file reload swaps documents without ever being unavailable; an occurrence
            // from the old document must not be carried into the new one.
            currentIndex = nil
            reveal = nil
            paneFocusRequest = nil
            intent = .firstMatch
        }
        displayed = newDisplayed
        displayedIdentity = (newDisplayed.contentID, newDisplayed.projectionID)
        schedule()
    }

    /// The panes show nothing searchable: another selection, a binary file, an error.
    func contentUnavailable() {
        displayed = nil
        displayedIdentity = nil
        cancel()
        results = nil
        currentIndex = nil
        reveal = nil
        paneFocusRequest = nil
        intent = .firstMatch
    }

    /// Steps within the searched side only; it never switches sides.
    func next() {
        guard canStep, let results else { return }
        step(to: DiffFinder.next(after: currentIndex, count: results.side(side).matches.count))
    }

    func previous() {
        guard canStep, let results else { return }
        step(to: DiffFinder.previous(before: currentIndex, count: results.side(side).matches.count))
    }

    /// Where the viewport is, so a fresh query lands on the first match in view.
    func noteVisibleRows(_ rows: Range<Int>, contentID: UUID) {
        visibleRows = (contentID, rows)
    }

    func acknowledgePaneFocus(id: UUID) {
        if paneFocusRequest?.id == id { paneFocusRequest = nil }
    }

    // MARK: Searching

    private func step(to index: Int?) {
        guard let results, let index, results.side(side).matches.indices.contains(index) else { return }
        let match = results.side(side).matches[index]
        currentIndex = index
        intent = .keep(occurrence: match, index: index)
        reveal = FindReveal(key: results.key, side: side, match: match)
    }

    private func cancel() {
        task?.cancel()
        task = nil
        generation += 1
    }

    /// The one place a search starts. A changed query waits out the debounce; a
    /// document update searches at once, and by restarting the task also cuts short a
    /// pending debounce, which is harmless because the intent decides the selection.
    private func schedule() {
        cancel()
        guard isPresented, let key = liveKey, let displayed else {
            results = nil
            currentIndex = nil
            return
        }
        let shouldDebounce = lastScheduledQuery != key.query
        lastScheduledQuery = key.query
        let gen = generation
        let search = search
        task = Task { [weak self] in
            if shouldDebounce {
                do { try await Task.sleep(for: Self.debounce) } catch { return }
            }
            guard let found = try? await search(key, displayed) else { return }
            self?.publish(found, generation: gen)
        }
    }

    private func publish(_ found: FindResults, generation gen: Int) {
        guard gen == generation, found.key == liveKey else { return }
        results = found
        resolveIntent(with: found)
    }

    /// Applies the live intent to the searched side of current results.
    private func resolveIntent(with found: FindResults) {
        let matches = found.side(side).matches
        switch intent {
        case .firstMatch:
            let top = visibleRows.flatMap { $0.contentID == found.key.contentID ? $0.rows.lowerBound : nil } ?? 0
            guard let index = DiffFinder.firstIndex(atOrAfterRow: top, in: matches) else {
                // Stays pending: a later revision may hold the first match.
                currentIndex = nil
                return
            }
            currentIndex = index
            reveal = FindReveal(key: found.key, side: side, match: matches[index])
            intent = .keep(occurrence: matches[index], index: index)
        case let .keep(occurrence, index):
            // No reveal: the reader is already looking at it, or it is folded away.
            guard let carried = DiffFinder.carriedIndex(of: occurrence, fallbackIndex: index, in: matches) else {
                currentIndex = nil
                return
            }
            currentIndex = carried
            intent = .keep(occurrence: matches[carried], index: carried)
        case .none:
            currentIndex = nil
        }
    }

    /// Runs off the main actor and stops the scan when the calling task is cancelled.
    nonisolated private static func searchInBackground(_ key: FindKey, _ displayed: DisplayedDocument)
        async throws -> FindResults
    {
        let worker = Task.detached(priority: .userInitiated) {
            try DiffFinder.results(for: key, in: displayed)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
