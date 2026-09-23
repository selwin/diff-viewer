import Foundation

/// One occurrence: a document row and a UTF-16 range in that side's raw line, the unit
/// `DiffSide.highlights` and `PaneSelection` already use.
struct FindMatch: Equatable, Sendable {
    let documentRow: Int
    let utf16Range: Range<Int>
}

/// What a search was run against. Selection and reveal require an exact key match; fills
/// may survive projection changes within the same content.
struct FindKey: Equatable, Sendable {
    let query: String
    let side: DocumentSide
    /// The changeset's loadID or the file document's id. Rows are append-only under one
    /// id, so a result's fills stay meaningful across appended revisions.
    let contentID: UUID
    /// Fresh for every projection the container shows. A UUID rather than a counter, so
    /// a recreated container for the same document can never collide with an old one.
    let projectionID: UUID

    /// Same document and same projection: what selection and reveals require. Says
    /// nothing about query, side, or whether the bar is open.
    func matchesProjection(contentID: UUID, projectionID: UUID) -> Bool {
        self.contentID == contentID && self.projectionID == projectionID
    }
}

/// What the panes currently show, reported by the container.
struct DisplayedDocument: Sendable {
    let document: DiffDocument
    let displayRows: [DisplayRow]
    let contentID: UUID
    let projectionID: UUID
}

struct FindResults: Sendable {
    let id = UUID()
    let key: FindKey
    /// Display order.
    let matches: [FindMatch]
    /// What the pane draws from.
    let rangesByRow: [Int: [Range<Int>]]
}

/// Validated for the panes: results whose query, side and content id are the live ones.
/// The projection id may lag; the container keeps such fills until the replacement search
/// completes and applies the selection only once the projection matches. Equality is by
/// results id and index: results are immutable snapshots, so the arrays need no comparing.
struct FindPresentation: Equatable {
    let results: FindResults
    let currentIndex: Int?

    static func == (a: Self, b: Self) -> Bool {
        a.results.id == b.results.id && a.currentIndex == b.currentIndex
    }
}

/// One-shot: bring this match into view. Carries the key it was stepped under.
struct FindReveal: Equatable, Sendable {
    let id = UUID()
    let key: FindKey
    let match: FindMatch
}

struct PaneFocusRequest: Equatable {
    let id = UUID()
    let side: DocumentSide
}

enum DiffFinder {
    /// Case-insensitive, non-overlapping matches over the `.documentRow` entries of
    /// `displayRows`, in display order; pad cells are skipped. Throws `CancellationError`
    /// when the task is cancelled, checked every 256 rows and every 64 hits in one line.
    static func matches(for query: String, in document: DiffDocument, side: DocumentSide, displayRows: [DisplayRow])
        throws -> [FindMatch]
    {
        guard !query.isEmpty else { return [] }
        try Task.checkCancellation()
        let lines = side == .old ? document.oldLines : document.newLines
        var matches: [FindMatch] = []
        var documentRowsScanned = 0
        for displayRow in displayRows {
            guard case let .documentRow(rowIndex) = displayRow else { continue }
            documentRowsScanned += 1
            if documentRowsScanned % 256 == 0 { try Task.checkCancellation() }
            let row = document.rows[rowIndex]
            guard let cell = side == .old ? row.old : row.new else { continue }
            let line = lines[cell.lineIndex] as NSString
            var searchStartUTF16 = 0
            var hitsInLine = 0
            while searchStartUTF16 < line.length {
                let found = line.range(
                    of: query, options: [.caseInsensitive],
                    range: NSRange(location: searchStartUTF16, length: line.length - searchStartUTF16))
                guard found.location != NSNotFound, found.length > 0 else { break }
                matches.append(FindMatch(documentRow: rowIndex, utf16Range: found.location..<NSMaxRange(found)))
                searchStartUTF16 = NSMaxRange(found)
                hitsInLine += 1
                if hitsInLine % 64 == 0 { try Task.checkCancellation() }
            }
        }
        return matches
    }

    /// The whole unit of background work: matches plus their grouping by row, so nothing
    /// is built on the main actor after the worker returns. The results carry `key`
    /// unchecked, so the caller must pass the snapshot the key's ids were taken from.
    static func results(for key: FindKey, in displayed: DisplayedDocument) throws -> FindResults {
        let matches = try matches(
            for: key.query, in: displayed.document, side: key.side, displayRows: displayed.displayRows)
        var rangesByRow: [Int: [Range<Int>]] = [:]
        for (index, match) in matches.enumerated() {
            if index % 4096 == 4095 { try Task.checkCancellation() }
            rangesByRow[match.documentRow, default: []].append(match.utf16Range)
        }
        return FindResults(key: key, matches: matches, rangesByRow: rangesByRow)
    }

    /// Wraps from the last match to the first (ChangeNavigator clamps instead).
    static func next(after current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return current + 1 < count ? current + 1 : 0
    }

    /// Wraps from the first match to the last.
    static func previous(before current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current > 0 else { return count - 1 }
        return min(current, count) - 1
    }

    /// Where a fresh query lands: the first match whose row is at or after `row` (the top
    /// of the viewport), wrapping to 0 when every match is above it; nil when empty.
    /// Binary search: `matches` must be in ascending row order, as `matches(for:)` returns them.
    static func firstIndex(atOrAfterRow row: Int, in matches: [FindMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if matches[mid].documentRow < row { low = mid + 1 } else { high = mid }
        }
        return low < matches.count ? low : 0
    }

    /// The index of `occurrence` in `matches`, or the clamped `fallbackIndex` when it is
    /// gone; nil when `matches` is empty. An append leaves the fallback slot in place, so
    /// checking it first keeps the common case constant-time. Row and range identify an
    /// occurrence only within one content id.
    static func carriedIndex(of occurrence: FindMatch, fallbackIndex: Int, in matches: [FindMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        let clamped = min(max(fallbackIndex, 0), matches.count - 1)
        if matches[clamped] == occurrence { return clamped }
        return matches.firstIndex(of: occurrence) ?? clamped
    }
}
