import Foundation
import Testing

@testable import DiffViewer

/// Row → original section index over a changeset, skipping sections without rows.
struct SectionIndexTests {
    private func section(_ path: String, rowRange: Range<Int>, outcome: FileOutcome = .text(language: nil))
        -> ChangesetSection
    {
        ChangesetSection(
            file: changedFile(path), rowRange: rowRange, oldLineOffset: 0, newLineOffset: 0, oldLineCount: 0,
            newLineCount: 0, added: 0, deleted: 0, outcome: outcome)
    }

    /// Two text files with an empty binary section between them, starting exactly where
    /// the second file's rows do.
    private var index: SectionIndex {
        SectionIndex(sections: [
            section("first.swift", rowRange: 0..<3),
            section("logo.png", rowRange: 3..<3, outcome: .binary),
            section("second.swift", rowRange: 3..<5),
        ])
    }

    @Test func firstAndLastRowOfASection() {
        #expect(index.sectionIndex(containingRow: 0) == 0)
        #expect(index.sectionIndex(containingRow: 2) == 0)
        #expect(index.sectionIndex(containingRow: 3) == 2)
        #expect(index.sectionIndex(containingRow: 4) == 2)
    }

    @Test func emptySectionsAreSkippedAndOriginalIndicesKept() {
        // The binary section shares row 3's boundary but is never chosen; the answer is
        // its neighbour's index in the original array, not in the filtered one.
        #expect(index.sectionIndex(containingRow: 3) == 2)
    }

    @Test func rowInAGapIsNil() {
        let gapped = SectionIndex(sections: [
            section("a.swift", rowRange: 0..<2),
            section("b.swift", rowRange: 4..<6),
        ])
        #expect(gapped.sectionIndex(containingRow: 1) == 0)
        #expect(gapped.sectionIndex(containingRow: 2) == nil)
        #expect(gapped.sectionIndex(containingRow: 3) == nil)
        #expect(gapped.sectionIndex(containingRow: 4) == 1)
    }

    @Test func rowPastTheEndIsNil() {
        #expect(index.sectionIndex(containingRow: 5) == nil)
        #expect(index.sectionIndex(containingRow: 100) == nil)
    }

    // MARK: Display rows

    /// Text, binary, text: the binary section has no rows, and its empty range starts
    /// where the third file's rows do.
    private var changeset: ChangesetDocument {
        ChangesetBuilder.build(
            results: [
                (changedFile("a.swift"), .content(textContent(rows: 100, modified: [50..<52]))),
                (changedFile("logo.png"), .content(.binary)),
                (changedFile("c.swift"), .content(textContent(rows: 100, modified: [50..<52]))),
            ],
            loadID: UUID(), revision: 1)
    }

    /// The first display index whose row matches, found by searching so the tests do not
    /// depend on where folding puts things.
    private func displayIndex(in folded: FoldedRows, where matches: (DisplayRow) -> Bool) throws -> Int {
        let found = folded.displayRows.firstIndex(where: matches)
        return try #require(found)
    }

    @Test func syntheticRowsCarryTheirSection() throws {
        let document = changeset
        let folded = document.folded
        let index = document.sectionIndex
        let header = try displayIndex(in: folded) {
            if case .fileHeader(let section) = $0 { return section == 0 }
            return false
        }
        // A spacer belongs to the file that follows it.
        let spacer = try displayIndex(in: folded) {
            if case .spacer(let section) = $0 { return section == 1 }
            return false
        }
        let notice = try displayIndex(in: folded) {
            if case .notice(let section) = $0 { return section == 1 }
            return false
        }
        #expect(index.sectionIndex(containingDisplayIndex: header, in: folded) == 0)
        #expect(index.sectionIndex(containingDisplayIndex: spacer, in: folded) == 1)
        #expect(index.sectionIndex(containingDisplayIndex: notice, in: folded) == 1)
    }

    @Test func documentRowsAndSeparatorsLookUpTheirSection() throws {
        let document = changeset
        let folded = document.folded
        let index = document.sectionIndex
        func separator(in rows: Range<Int>) throws -> Int {
            try displayIndex(in: folded) {
                if case .separator(let hidden) = $0 { return rows.contains(hidden.lowerBound) }
                return false
            }
        }
        func documentRow(in rows: Range<Int>) throws -> Int {
            try displayIndex(in: folded) {
                if case .documentRow(let row) = $0 { return rows.contains(row) }
                return false
            }
        }
        let firstRows = document.sections[0].rowRange
        let separatorInFirst = try separator(in: firstRows)
        let rowInFirst = try documentRow(in: firstRows)
        #expect(index.sectionIndex(containingDisplayIndex: separatorInFirst, in: folded) == 0)
        #expect(index.sectionIndex(containingDisplayIndex: rowInFirst, in: folded) == 0)
        // Past the binary section, whose empty range starts where the third file's rows do.
        let thirdRows = document.sections[2].rowRange
        let separatorInThird = try separator(in: thirdRows)
        let rowInThird = try documentRow(in: thirdRows)
        #expect(index.sectionIndex(containingDisplayIndex: separatorInThird, in: folded) == 2)
        #expect(index.sectionIndex(containingDisplayIndex: rowInThird, in: folded) == 2)
    }

    @Test func noSectionsIsNil() {
        #expect(SectionIndex(sections: []).sectionIndex(containingRow: 0) == nil)
        #expect(
            SectionIndex(sections: [section("logo.png", rowRange: 0..<0, outcome: .binary)])
                .sectionIndex(containingRow: 0) == nil)
    }
}
