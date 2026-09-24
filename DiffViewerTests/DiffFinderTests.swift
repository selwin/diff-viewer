import Foundation
import Testing

@testable import DiffViewer

struct DiffFinderTests {
    private func document(old: [String], new: [String], rows: [DiffRow]) -> DiffDocument {
        DiffDocument(oldLines: old, newLines: new, rows: rows, language: nil)
    }

    /// One equal row per line, identical on both sides.
    private func equalDocument(_ lines: [String]) -> DiffDocument {
        document(old: lines, new: lines, rows: lines.indices.map { DiffRow.equal(old: $0, new: $0) })
    }

    private func identity(_ document: DiffDocument) -> [DisplayRow] {
        document.rows.indices.map { .documentRow($0) }
    }

    private func find(_ query: String, in document: DiffDocument, side: DocumentSide = .new) throws -> [FindMatch] {
        try DiffFinder.matches(for: query, in: document, side: side, displayRows: identity(document))
    }

    private func match(_ row: Int, _ range: Range<Int>) -> FindMatch {
        FindMatch(documentRow: row, utf16Range: range)
    }

    // MARK: Matching

    @Test func searchesOnlyShownRowsOnOneSide() throws {
        let doc = document(
            old: ["foo eq", "foo mod", "foo gone", "foo tail"],
            new: ["foo eq", "foo MOD", "foo added", "foo tail"],
            rows: [
                DiffRow.equal(old: 0, new: 0), modifiedRow(1, 1), addedRow(2), deletedRow(2),
                DiffRow.equal(old: 3, new: 3),
            ])
        let display: [DisplayRow] = [
            .fileHeader(section: 0), .documentRow(0), .documentRow(1), .documentRow(2), .documentRow(3),
            .separator(hidden: 4..<5), .notice(section: 0),
        ]
        let newSide = try DiffFinder.matches(for: "foo", in: doc, side: .new, displayRows: display)
        #expect(newSide == [match(0, 0..<3), match(1, 0..<3), match(2, 0..<3)])
        let oldSide = try DiffFinder.matches(for: "foo", in: doc, side: .old, displayRows: display)
        #expect(oldSide == [match(0, 0..<3), match(1, 0..<3), match(3, 0..<3)])
    }

    @Test func adjacentOccurrencesDoNotOverlap() throws {
        #expect(try find("aa", in: equalDocument(["aaaa"])) == [match(0, 0..<2), match(0, 2..<4)])
    }

    @Test func matchesIgnoreCase() throws {
        let found = try find("Foo", in: equalDocument(["foo", "FOO", "fOo"]))
        #expect(found == [match(0, 0..<3), match(1, 0..<3), match(2, 0..<3)])
    }

    @Test func rangesAreUTF16() throws {
        let doc = equalDocument(["héllo 😀 foo"])
        #expect(try find("foo", in: doc) == [match(0, 9..<12)])
        #expect(try find("😀", in: doc) == [match(0, 6..<8)])
    }

    @Test func emptyQueryMatchesNothing() throws {
        #expect(try find("", in: equalDocument(["anything"])).isEmpty)
    }

    @Test func resultsGroupRangesByRowForBothSides() throws {
        let doc = document(
            old: ["ab", "ab ab", "x"], new: ["x", "ab ab", "ab"],
            rows: (0..<3).map { DiffRow.equal(old: $0, new: $0) })
        let key = FindKey(query: "ab", contentID: UUID(), projectionID: UUID())
        let displayed = DisplayedDocument(
            document: doc, displayRows: identity(doc), contentID: key.contentID, projectionID: key.projectionID)
        let results = try DiffFinder.results(for: key, in: displayed)
        #expect(results.new.matches.count == 3)
        #expect(results.new.rangesByRow == [1: [0..<2, 3..<5], 2: [0..<2]])
        #expect(results.old.matches.map(\.documentRow) == [0, 1, 1])
        #expect(results.old.rangesByRow == [0: [0..<2], 1: [0..<2, 3..<5]])
        #expect(results.side(.old).rangesByRow == results.old.rangesByRow)
    }

    // MARK: Stepping

    @Test func stepsWrapAtBothEnds() {
        #expect(DiffFinder.next(after: nil, count: 3) == 0)
        #expect(DiffFinder.next(after: 1, count: 3) == 2)
        #expect(DiffFinder.next(after: 2, count: 3) == 0)
        #expect(DiffFinder.next(after: nil, count: 0) == nil)
        #expect(DiffFinder.previous(before: nil, count: 3) == 2)
        #expect(DiffFinder.previous(before: 2, count: 3) == 1)
        #expect(DiffFinder.previous(before: 0, count: 3) == 2)
        #expect(DiffFinder.previous(before: 1, count: 0) == nil)
    }

    @Test func firstIndexLandsAtOrBelowRow() {
        let matches = [match(2, 0..<1), match(5, 0..<1), match(5, 2..<3), match(9, 0..<1)]
        #expect(DiffFinder.firstIndex(atOrAfterRow: 5, in: matches) == 1)
        #expect(DiffFinder.firstIndex(atOrAfterRow: 6, in: matches) == 3)
        #expect(DiffFinder.firstIndex(atOrAfterRow: 10, in: matches) == 0)
        let none = DiffFinder.firstIndex(atOrAfterRow: 0, in: [])
        #expect(none == nil)
    }

    // MARK: Carrying the current match

    @Test func appendKeepsEarlierIndices() throws {
        let original = try find("foo", in: equalDocument((0..<10).map { "foo \($0)" }))
        let appended = try find("foo", in: equalDocument((0..<15).map { "foo \($0)" }))
        #expect(Array(appended.prefix(original.count)) == original)
        #expect(DiffFinder.carriedIndex(of: original[3], fallbackIndex: 3, in: appended) == 3)
        #expect(DiffFinder.carriedIndex(of: match(99, 0..<3), fallbackIndex: 50, in: appended) == 14)
        #expect(DiffFinder.carriedIndex(of: original[3], fallbackIndex: 3, in: []) == nil)
    }

    @Test func foldedRunsHideMatchesUntilExpanded() throws {
        var old = (0..<30).map { "line \($0)" }
        old[2] = "needle a"
        old[3] = "needle b"
        old[12] = "needle kept"
        var new = old
        new[15] = "changed"
        let rows = (0..<30).map { $0 == 15 ? modifiedRow(15, 15) : DiffRow.equal(old: $0, new: $0) }
        let doc = document(old: old, new: new, rows: rows)
        let options = FoldOptions(contextLines: 5, expansionStep: 20, minimumHiddenRun: 4)
        func search(_ state: FoldState) throws -> [FindMatch] {
            let folded = RowFolding.fold(
                changeBlocks: doc.changeBlocks, documentRowCount: doc.rows.count, state: state, options: options)
            return try DiffFinder.matches(for: "needle", in: doc, side: .new, displayRows: folded.displayRows)
        }

        let folded = try search(FoldState())
        #expect(folded == [match(12, 0..<6)])

        var state = FoldState()
        state.expandRun(0..<10)
        let expanded = try search(state)
        #expect(expanded.map(\.documentRow) == [2, 3, 12])
        #expect(DiffFinder.carriedIndex(of: folded[0], fallbackIndex: 0, in: expanded) == 2)
    }

    // MARK: Cancellation and keys

    @Test func cancellationStopsInsideOneLine() async {
        let doc = equalDocument([String(repeating: "a", count: 10_000)])
        let display = identity(doc)
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try DiffFinder.matches(for: "a", in: doc, side: .new, displayRows: display)
                return false
            } catch {
                return error is CancellationError
            }
        }
        #expect(await task.value)
    }

    @Test func projectionMatchRequiresSameContentAndProjection() {
        let content = UUID()
        let projection = UUID()
        let key = FindKey(query: "q", contentID: content, projectionID: projection)
        #expect(key.matchesProjection(contentID: content, projectionID: projection))
        #expect(!key.matchesProjection(contentID: UUID(), projectionID: projection))
        #expect(!key.matchesProjection(contentID: content, projectionID: UUID()))
    }
}
