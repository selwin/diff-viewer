import Foundation
import Testing

@testable import DiffViewer

struct ChangesetProjectionTests {
    private let options = FoldOptions(contextLines: 5, expansionStep: 20, minimumHiddenRun: 4)

    private func changeset(_ results: [(file: ChangedFile, result: ChangesetBuilder.FileResult)]) -> ChangesetDocument {
        ChangesetBuilder.build(results: results, loadID: UUID(), revision: 1)
    }

    /// One text file of `rows` rows with a change at 50..<52, folded to context 5.
    private func textFile(_ path: String) -> (file: ChangedFile, result: ChangesetBuilder.FileResult) {
        (changedFile(path), .content(textContent(rows: 100, modified: [50..<52])))
    }

    private func binaryFile(_ path: String) -> (file: ChangedFile, result: ChangesetBuilder.FileResult) {
        (changedFile(path), .content(.binary))
    }

    private func project(_ document: ChangesetDocument) -> FoldedRows {
        ChangesetProjection.build(document: document, options: options)
    }

    /// Collapses runs of `.documentRow` into ranges, like `RowFoldingTests`, and names
    /// synthetic rows by their section.
    private func shape(_ folded: FoldedRows) -> [String] {
        var out: [String] = []
        var run: Range<Int>?
        func flush() { if let r = run { out.append("rows \(r.lowerBound)..<\(r.upperBound)"); run = nil } }
        for row in folded.displayRows {
            switch row {
            case let .documentRow(i):
                if let r = run, r.upperBound == i { run = r.lowerBound..<(i + 1) } else { flush(); run = i..<(i + 1) }
            case let .separator(hidden):
                flush()
                out.append("sep \(hidden.lowerBound)..<\(hidden.upperBound)")
            case let .fileHeader(section):
                flush()
                out.append("hdr \(section)")
            case let .spacer(section):
                flush()
                out.append("sp \(section)")
            case let .notice(section):
                flush()
                out.append("note \(section)")
            }
        }
        flush()
        return out
    }

    /// Every display row maps to a document row at least as large as the one before it,
    /// and never past the end of the document.
    private func isMonotonic(_ folded: FoldedRows) -> Bool {
        var previous = 0
        for index in folded.displayRows.indices {
            let row = folded.documentRow(forDisplayIndex: index)
            if row < previous || row > folded.documentRowCount { return false }
            previous = row
        }
        return true
    }

    // MARK: Shape

    @Test func eachFileIsFoldedOnItsOwnBlocks() {
        let folded = project(changeset([textFile("a.swift"), textFile("b.swift")]))
        #expect(
            shape(folded) == [
                "hdr 0", "sep 0..<45", "rows 45..<57", "sep 57..<100",
                "sp 1", "hdr 1", "sep 100..<145", "rows 145..<157", "sep 157..<200",
            ])
        #expect(isMonotonic(folded))
    }

    @Test func aGapStraddlingTwoFilesIsTwoSeparators() {
        let folded = project(changeset([textFile("a.swift"), textFile("b.swift")]))
        let separators = folded.displayRows.compactMap { row -> Range<Int>? in
            if case let .separator(hidden) = row { return hidden }
            return nil
        }
        // The equal rows 57..<145 straddle the boundary at 100 and never merge.
        #expect(separators == [0..<45, 57..<100, 100..<145, 157..<200])
    }

    @Test func noSpacerBeforeTheFirstSection() {
        let folded = project(changeset([textFile("a.swift")]))
        #expect(shape(folded).first == "hdr 0")
        #expect(folded.displayRows.contains(.spacer(section: 0)) == false)
    }

    // MARK: Mapping

    @Test func displayToDocumentCoversSourceRowsSeparatorsAndSyntheticRows() {
        let folded = project(changeset([textFile("a.swift"), textFile("b.swift")]))
        // 0 hdr, 1 sep 0..<45, 2...13 rows 45..<57, 14 sep 57..<100, 15 sp, 16 hdr,
        // 17 sep 100..<145, 18...29 rows 145..<157, 30 sep 157..<200.
        #expect(folded.displayRows.count == 31)
        #expect(folded.documentRow(forDisplayIndex: 0) == 0)  // header before the first section
        #expect(folded.documentRow(forDisplayIndex: 1) == 0)
        #expect(folded.documentRow(forDisplayIndex: 2) == 45)
        #expect(folded.documentRow(forDisplayIndex: 14) == 57)
        #expect(folded.documentRow(forDisplayIndex: 15) == 100)  // spacer of the second section
        #expect(folded.documentRow(forDisplayIndex: 16) == 100)  // its header
        #expect(folded.documentRow(forDisplayIndex: 18) == 145)
        #expect(folded.documentRow(forDisplayIndex: 30) == 157)
    }

    @Test func documentToDisplayIsUnchangedForSourceRows() {
        let folded = project(changeset([textFile("a.swift"), textFile("b.swift")]))
        #expect(folded.documentRowCount == 200)
        #expect(folded.displayIndex(forDocumentRow: 0) == 1)
        #expect(folded.displayIndex(forDocumentRow: 45) == 2)
        #expect(folded.displayIndex(forDocumentRow: 57) == 14)
        #expect(folded.displayIndex(forDocumentRow: 100) == 17)
        #expect(folded.displayIndex(forDocumentRow: 145) == 18)
        #expect(folded.displayIndex(forDocumentRow: 199) == 30)
        #expect(folded.displayRange(forDocumentRange: 150..<152) == 23..<25)
    }

    @Test func aRangeOfOnlySyntheticRowsIsEmptyAtItsBoundary() {
        let folded = project(changeset([textFile("a.swift"), textFile("b.swift")]))
        #expect(folded.documentRange(forDisplayRange: 15..<17) == 100..<100)
        #expect(folded.documentRange(forDisplayRange: 0..<1) == 0..<0)
    }

    @Test func aRangeEndingOnSourceRowsIgnoresSyntheticOnes() {
        let folded = project(changeset([textFile("a.swift"), textFile("b.swift")]))
        #expect(folded.documentRange(forDisplayRange: 14..<17) == 57..<100)
        #expect(folded.documentRange(forDisplayRange: 13..<19) == 56..<146)
        #expect(folded.documentRange(forDisplayRange: 0..<31) == 0..<200)
    }

    // MARK: Sections with no rows

    @Test func aBinarySectionBetweenTwoFilesIsOneNotice() {
        let folded = project(changeset([textFile("a.swift"), binaryFile("logo.png"), textFile("c.swift")]))
        #expect(
            shape(folded) == [
                "hdr 0", "sep 0..<45", "rows 45..<57", "sep 57..<100",
                "sp 1", "hdr 1", "note 1",
                "sp 2", "hdr 2", "sep 100..<145", "rows 145..<157", "sep 157..<200",
            ])
        // 14 sep 57..<100, 15 sp 1, 16 hdr 1, 17 note 1, 18 sp 2, 19 hdr 2, 20 sep 100..<145.
        #expect(folded.documentRow(forDisplayIndex: 17) == 100)
        // A viewport that starts in one file and runs through the notice into the next.
        #expect(folded.documentRange(forDisplayRange: 14..<22) == 57..<146)
        #expect(isMonotonic(folded))
    }

    @Test func aBinarySectionBeforeAndAfterTextMapsToTheSectionBoundary() {
        let leading = project(changeset([binaryFile("logo.png"), textFile("a.swift")]))
        #expect(shape(leading) == ["hdr 0", "note 0", "sp 1", "hdr 1", "sep 0..<45", "rows 45..<57", "sep 57..<100"])
        #expect(leading.documentRow(forDisplayIndex: 0) == 0)
        #expect(leading.documentRow(forDisplayIndex: 1) == 0)
        #expect(isMonotonic(leading))

        let trailing = project(changeset([textFile("a.swift"), binaryFile("logo.png")]))
        #expect(
            shape(trailing) == ["hdr 0", "sep 0..<45", "rows 45..<57", "sep 57..<100", "sp 1", "hdr 1", "note 1"])
        // A trailing empty section sits at the end of the document.
        #expect(trailing.documentRowCount == 100)
        #expect(trailing.documentRow(forDisplayIndex: 16) == 100)
        #expect(trailing.documentRange(forDisplayRange: 15..<17) == 100..<100)
        #expect(isMonotonic(trailing))
    }

    @Test func anAllBinaryChangesetHasNoDocumentRows() {
        let folded = project(changeset([binaryFile("logo.png"), binaryFile("icon.png")]))
        #expect(shape(folded) == ["hdr 0", "note 0", "sp 1", "hdr 1", "note 1"])
        #expect(folded.documentRowCount == 0)
        for index in folded.displayRows.indices { #expect(folded.documentRow(forDisplayIndex: index) == 0) }
        #expect(folded.documentRange(forDisplayRange: 0..<5) == 0..<0)
        #expect(isMonotonic(folded))
    }

    @Test func aBlockLessTextSectionIsANotice() {
        let unchanged = (
            changedFile("ws.swift"), ChangesetBuilder.FileResult.content(textContent(rows: 10, modified: []))
        )
        let folded = project(changeset([unchanged, textFile("a.swift")]))
        #expect(shape(folded) == ["hdr 0", "note 0", "sp 1", "hdr 1", "sep 0..<45", "rows 45..<57", "sep 57..<100"])
        #expect(isMonotonic(folded))
    }
}
