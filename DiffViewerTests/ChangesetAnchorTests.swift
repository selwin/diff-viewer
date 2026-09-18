import Foundation
import Testing

@testable import DiffViewer

struct ChangesetAnchorTests {
    private func changeset(_ results: [(file: ChangedFile, result: ChangesetBuilder.FileResult)]) -> ChangesetDocument {
        ChangesetBuilder.build(results: results, loadID: UUID(), revision: 1)
    }

    /// A text file of `rows` rows with one change block, so the section folds.
    private func textFile(_ path: String, rows: Int = 100, modified: Range<Int> = 50..<52)
        -> (file: ChangedFile, result: ChangesetBuilder.FileResult)
    {
        (changedFile(path), .content(textContent(rows: rows, modified: [modified])))
    }

    private func binaryFile(_ path: String) -> (file: ChangedFile, result: ChangesetBuilder.FileResult) {
        (changedFile(path), .content(.binary))
    }

    /// `count` rows of which row `deletedAt` exists on the old side only, so the new side
    /// runs one line short.
    private func deletionFile(_ path: String, rows count: Int, deletedAt: Int)
        -> (file: ChangedFile, result: ChangesetBuilder.FileResult)
    {
        let rows = (0..<count).map { index -> DiffRow in
            if index == deletedAt { return deletedRow(index) }
            return DiffRow.equal(old: index, new: index < deletedAt ? index : index - 1)
        }
        let old = (0..<count).map { "line \($0)" }
        var new = old
        new.remove(at: deletedAt)
        let document = DiffDocument(oldLines: old, newLines: new, rows: rows, language: "Swift")
        return (changedFile(path), .content(.text(document)))
    }

    private func headerIndex(_ changeset: ChangesetDocument, section: Int) -> Int? {
        changeset.folded.displayRows.firstIndex(of: .fileHeader(section: section))
    }

    private func displayIndex(_ changeset: ChangesetDocument, documentRow: Int) -> Int {
        changeset.folded.displayIndex(forDocumentRow: documentRow)
    }

    @Test func aRowKeepsItsFileAndLineWhenAnEarlierFileGrows() {
        let from = changeset([textFile("a.swift"), textFile("b.swift")])
        let to = changeset([textFile("a.swift", rows: 120, modified: 50..<72), textFile("b.swift")])
        // b's local row 50 is document row 150 in `from` and 170 in `to`.
        let anchor = displayIndex(from, documentRow: 150)

        let translated = ChangesetAnchor.translate(displayIndex: anchor, from: from, to: to)

        #expect(translated == displayIndex(to, documentRow: 170))
    }

    @Test func aDeletedRowIsMatchedOnItsOldSide() {
        let from = changeset([deletionFile("a.swift", rows: 100, deletedAt: 50)])
        let to = changeset([textFile("x.swift"), deletionFile("a.swift", rows: 100, deletedAt: 50)])
        // The deleted row has no new side; its old line 50 lands on document row 150.
        let anchor = displayIndex(from, documentRow: 50)

        let translated = ChangesetAnchor.translate(displayIndex: anchor, from: from, to: to)

        #expect(translated == displayIndex(to, documentRow: 150))
    }

    @Test func aHeaderSpacerOrNoticeLandsOnTheSameFilesHeader() throws {
        let from = changeset([textFile("a.swift"), binaryFile("logo.png"), textFile("c.swift")])
        let to = changeset([textFile("x.swift"), textFile("a.swift"), binaryFile("logo.png"), textFile("c.swift")])
        let expected = try #require(headerIndex(to, section: 2))

        for row in [DisplayRow.fileHeader(section: 1), .spacer(section: 1), .notice(section: 1)] {
            let anchor = try #require(from.folded.displayRows.firstIndex(of: row))
            #expect(ChangesetAnchor.translate(displayIndex: anchor, from: from, to: to) == expected)
        }
    }

    @Test func aSeparatorKeepsItsFileAndLineWhenAnEarlierFileGrows() throws {
        let from = changeset([textFile("a.swift"), textFile("b.swift")])
        let to = changeset([textFile("a.swift", rows: 120, modified: 50..<72), textFile("b.swift")])
        // b's leading separator hides its local rows 0..<45, document rows 100..<145.
        let anchor = try #require(
            from.folded.displayRows.firstIndex {
                if case let .separator(hidden) = $0 { return hidden.lowerBound == 100 }
                return false
            })

        let translated = ChangesetAnchor.translate(displayIndex: anchor, from: from, to: to)

        // b's local row 0 is document row 120 in `to`, inside b's leading separator there.
        #expect(translated == displayIndex(to, documentRow: 120))
    }

    @Test func aLinePastTheEndOfTheNewSectionLandsOnItsLastRow() {
        let from = changeset([textFile("a.swift")])
        let to = changeset([textFile("a.swift", rows: 30, modified: 10..<12)])
        let anchor = displayIndex(from, documentRow: 55)

        let translated = ChangesetAnchor.translate(displayIndex: anchor, from: from, to: to)

        #expect(translated == displayIndex(to, documentRow: 29))
    }

    @Test func aSectionThatTurnedBinaryLandsOnItsHeader() {
        let from = changeset([textFile("a.swift")])
        let to = changeset([binaryFile("a.swift")])
        let anchor = displayIndex(from, documentRow: 50)

        let translated = ChangesetAnchor.translate(displayIndex: anchor, from: from, to: to)

        #expect(translated == headerIndex(to, section: 0))
    }

    @Test func aFileThatIsGoneLandsOnTheNextSurvivingFilesHeader() {
        let from = changeset([textFile("a.swift"), textFile("b.swift"), textFile("c.swift")])
        let to = changeset([textFile("z.swift"), textFile("b.swift"), textFile("c.swift")])
        let anchor = displayIndex(from, documentRow: 50)

        let translated = ChangesetAnchor.translate(displayIndex: anchor, from: from, to: to)

        #expect(translated == headerIndex(to, section: 1))
    }

    @Test func noSurvivingFileLandsOnTheLastSectionsHeader() {
        let from = changeset([textFile("a.swift"), textFile("b.swift")])
        let to = changeset([textFile("x.swift"), textFile("y.swift")])
        let anchor = displayIndex(from, documentRow: 50)

        let translated = ChangesetAnchor.translate(displayIndex: anchor, from: from, to: to)

        #expect(translated == headerIndex(to, section: 1))
    }

    @Test func anEmptyNewChangesetHasNowhereToGo() {
        let from = changeset([textFile("a.swift")])
        let to = changeset([])
        let anchor = displayIndex(from, documentRow: 50)

        #expect(ChangesetAnchor.translate(displayIndex: anchor, from: from, to: to) == nil)
    }

    @Test func anOutOfRangeDisplayIndexIsRejected() {
        let from = changeset([textFile("a.swift")])
        let to = changeset([textFile("a.swift")])

        #expect(ChangesetAnchor.translate(displayIndex: -1, from: from, to: to) == nil)
        #expect(ChangesetAnchor.translate(displayIndex: from.folded.displayRows.count, from: from, to: to) == nil)
    }
}
