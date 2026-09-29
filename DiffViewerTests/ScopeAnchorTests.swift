import SwiftTreeSitter
import Testing

@testable import DiffViewer

/// Where each side reads a change block's scope from, and the names that gives.
struct ScopeAnchorTests {
    private func outline(_ lines: [String]) throws -> ScopeOutline {
        let config = try #require(LanguageRegistry.configuration(forFileNamed: "a.swift"))
        let rules = try #require(LanguageRegistry.scopeRules(forFileNamed: "a.swift"))
        let text = lines.joined(separator: "\n")
        let parser = Parser()
        try parser.setLanguage(config.language)
        let tree = try #require(parser.parse(text))
        return ScopeOutline.build(tree: tree, text: text, lines: lines, rules: rules)
    }

    /// Anchors for a single file, whose blocks come from the document as the app builds them.
    private func anchors(_ rows: [DiffRow], side: DocumentSide) -> [ScopeAnchor] {
        let document = DiffDocument(oldLines: [], newLines: [], rows: rows, language: nil)
        return ScopeAnchor.anchors(changeBlocks: document.changeBlocks, rows: rows, side: side) { _, _ in true }
    }

    @Test func modifiedRowAnchorsToItsLineOnBothSides() {
        let rows = [DiffRow.equal(old: 0, new: 0), modifiedRow(1, 1), .equal(old: 2, new: 2)]
        #expect(anchors(rows, side: .old) == [.line(1)])
        #expect(anchors(rows, side: .new) == [.line(1)])
    }

    @Test func insertionAnchorsTheOldSideBetweenItsNeighbours() {
        let rows = [DiffRow.equal(old: 0, new: 0), addedRow(1), addedRow(2), .equal(old: 1, new: 3)]
        #expect(anchors(rows, side: .old) == [.between(before: 0, after: 1)])
        #expect(anchors(rows, side: .new) == [.line(1)])
    }

    @Test func insertionAtStartOfFileHasNoLineBefore() {
        let rows = [addedRow(0), DiffRow.equal(old: 0, new: 1)]
        #expect(anchors(rows, side: .old) == [.between(before: nil, after: 0)])
    }

    /// A pane over `rows` with one file per range in `files`, blocks split at each file's
    /// start as the changeset builder does.
    private func pane(
        _ rows: [DiffRow], files: [Range<Int>] = [], side: DocumentSide = .old, reusing: [ScopeAnchor] = []
    ) -> PaneModel {
        let sections = files.enumerated().map { index, range in
            ChangesetSection(
                file: changedFile("\(index).swift"), rowRange: range, oldLineOffset: 0, newLineOffset: 0,
                oldLineCount: range.count, newLineCount: range.count, added: 0, deleted: 0,
                outcome: .text(language: nil))
        }
        let document = DiffDocument(
            oldLines: [], newLines: [], rows: rows, language: nil, blockBoundaries: files.dropFirst().map(\.lowerBound))
        return PaneModel(
            side: side, rows: rows, lines: [], sections: sections, changeBlocks: document.changeBlocks,
            reusingScopeAnchors: reusing)
    }

    /// The row before the insertion belongs to the previous file, so it is not a neighbour.
    @Test func insertionAtStartOfChangesetSectionHasNoLineBefore() {
        let rows = [DiffRow.equal(old: 0, new: 0), .equal(old: 1, new: 1), addedRow(2), .equal(old: 2, new: 3)]
        #expect(pane(rows, files: [0..<2, 2..<4]).scopeAnchors == [.between(before: nil, after: 2)])
    }

    /// The first file ends in an insertion, whose old-side neighbour after it only exists
    /// once the second file is appended; it must still read as nil.
    @Test func anchorsReusedOnAppendMatchAFullRebuild() {
        let rows = [
            DiffRow.equal(old: 0, new: 0), addedRow(1),
            addedRow(2), .equal(old: 1, new: 3), modifiedRow(2, 4),
        ]
        for side in [DocumentSide.old, .new] {
            let first = pane(Array(rows[0..<2]), files: [0..<2], side: side)
            let appended = pane(rows, files: [0..<2, 2..<5], side: side, reusing: first.scopeAnchors)
            let full = pane(rows, files: [0..<2, 2..<5], side: side)
            #expect(first.scopeAnchors.count == 1)
            #expect(appended.scopeAnchors == full.scopeAnchors)
        }
    }

    @Test func separatorReadsTheNextChangeInItsFile() {
        let rows = (0..<3).map { DiffRow.equal(old: $0, new: $0) } + [modifiedRow(3, 3), .equal(old: 4, new: 4)]
        let single = pane(rows)
        #expect(single.scopeAnchor(after: 0..<3) == .line(3))
        #expect(single.scopeAnchor(after: 4..<5) == nil)
    }

    /// A trailing separator's next change is in the next file, so it names nothing; the
    /// next file's own leading separator names its change.
    @Test func separatorDoesNotReadAChangeInTheNextFile() {
        let rows = [
            modifiedRow(0, 0), .equal(old: 1, new: 1), .equal(old: 2, new: 2),
            .equal(old: 3, new: 3), modifiedRow(4, 4),
        ]
        let changeset = pane(rows, files: [0..<3, 3..<5])
        #expect(changeset.scopeAnchor(after: 1..<3) == nil)
        #expect(changeset.scopeAnchor(after: 3..<4) == .line(4))
    }

    @Test func lineNamesItsTwoInnermostScopes() throws {
        let old = try outline([
            "class Cart {",
            "    var items = 0",
            "    func total() -> Int {",
            "        0",
            "    }",
            "    struct Line {",
            "        func price() -> Int {",
            "            1",
            "        }",
            "    }",
            "}",
        ])
        #expect(ScopeAnchor.line(3).names(in: old) == ["Cart", "total"])
        #expect(ScopeAnchor.line(7).names(in: old) == ["Line", "price"])
        #expect(ScopeAnchor.line(1).names(in: old) == ["Cart"])
    }

    @Test func topLevelFunctionHasOneName() throws {
        let old = try outline(["func parse() {", "    a()", "}"])
        #expect(ScopeAnchor.line(1).names(in: old) == ["parse"])
    }

    @Test func insertionBetweenMethodsNamesTheEnclosingType() throws {
        let old = try outline([
            "class Cart {",
            "    func total() -> Int {",
            "        0",
            "    }",
            "",  // 4: the new method goes here
            "    func count() -> Int {",
            "        1",
            "    }",
            "}",
        ])
        #expect(ScopeAnchor.between(before: 4, after: 5).names(in: old) == ["Cart"])
        #expect(ScopeAnchor.between(before: 3, after: 4).names(in: old) == ["Cart"])
    }

    @Test func insertionInsideFunctionNamesThatFunction() throws {
        let old = try outline([
            "func run() {",
            "    a()",
            "    b()",
            "}",
        ])
        #expect(ScopeAnchor.between(before: 1, after: 2).names(in: old) == ["run"])
        #expect(ScopeAnchor.between(before: nil, after: 2).names(in: old).isEmpty)
    }

    @Test func renamedFunctionGivesEachSideItsOwnName() throws {
        let old = try outline(["func total() -> Int {", "    0", "}"])
        let new = try outline(["func sum() -> Int {", "    0", "}"])
        let rows = [modifiedRow(0, 0), DiffRow.equal(old: 1, new: 1), .equal(old: 2, new: 2)]
        let oldNames = anchors(rows, side: .old).first?.names(in: old)
        let newNames = anchors(rows, side: .new).first?.names(in: new)
        #expect(oldNames == ["total"])
        #expect(newNames == ["sum"])
    }
}
