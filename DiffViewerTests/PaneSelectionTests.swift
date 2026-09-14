import Testing

@testable import DiffViewer

struct PaneSelectionTests {
    /// Four rows: two equal, one modified, one added (a pad on the old side).
    private static let rows: [DiffRow] = [
        .equal(old: 0, new: 0),
        DiffRow(
            kind: .modified, old: DiffSide(lineIndex: 1, highlights: []),
            new: DiffSide(lineIndex: 1, highlights: [])),
        DiffRow(kind: .added, old: nil, new: DiffSide(lineIndex: 2, highlights: [])),
        .equal(old: 2, new: 3),
    ]
    private static let oldLines = ["alpha", "beta", "gamma"]
    private static let newLines = ["alpha", "delta", "inserted", "gamma"]

    private static let oldModel = PaneModel(side: .old, rows: rows, lines: oldLines)
    private static let newModel = PaneModel(side: .new, rows: rows, lines: newLines)

    private static func position(_ row: Int, _ offset: Int) -> TextPosition {
        TextPosition(row: row, offset: offset)
    }

    private static func selection(_ start: TextPosition, _ end: TextPosition) -> PaneSelection {
        PaneSelection(anchor: start, head: end)
    }

    // MARK: - Ordering

    @Test func reversedSelectionNormalizes() {
        let backwards = Self.selection(Self.position(2, 1), Self.position(0, 3))
        #expect(backwards.start == Self.position(0, 3))
        #expect(backwards.end == Self.position(2, 1))
        #expect(!backwards.isEmpty)
        #expect(Self.selection(Self.position(1, 4), Self.position(1, 4)).isEmpty)
        #expect(Self.position(1, 9) < Self.position(2, 0))
        #expect(Self.position(1, 2) < Self.position(1, 3))
    }

    // MARK: - Per-row ranges

    @Test func rangeSpansFirstMiddleAndLastRows() {
        let selection = Self.selection(Self.position(1, 2), Self.position(3, 4))
        #expect(selection.range(forRow: 0, lineLength: 5) == nil)
        #expect(selection.range(forRow: 1, lineLength: 5) == 2..<5)
        #expect(selection.range(forRow: 2, lineLength: 8) == 0..<8)
        #expect(selection.range(forRow: 3, lineLength: 5) == 0..<4)
        #expect(selection.range(forRow: 4, lineLength: 5) == nil)
    }

    @Test func rangeClampsToLineLength() {
        let single = Self.selection(Self.position(1, 2), Self.position(1, 9))
        #expect(single.range(forRow: 1, lineLength: 5) == 2..<5)
        let past = Self.selection(Self.position(1, 7), Self.position(3, 99))
        #expect(past.range(forRow: 1, lineLength: 5) == 5..<5)
        #expect(past.range(forRow: 3, lineLength: 5) == 0..<5)
    }

    @Test func lineEndIsSelectedOnEveryRowButTheLast() {
        let selection = Self.selection(Self.position(1, 2), Self.position(3, 4))
        #expect(selection.includesLineEnd(ofRow: 1))
        #expect(selection.includesLineEnd(ofRow: 2))
        #expect(!selection.includesLineEnd(ofRow: 3))
    }

    // MARK: - Words

    @Test func wordSelectionCoversIdentifiers() {
        let line = "let value_1 = 42"
        #expect(WordSelection.range(in: line, at: 4) == 4..<11)
        #expect(WordSelection.range(in: line, at: 7) == 4..<11)
        #expect(WordSelection.range(in: line, at: 0) == 0..<3)
        #expect(WordSelection.range(in: line, at: line.utf16.count) == 14..<16)
    }

    @Test func wordSelectionCoversWhitespaceRunsAndSingleCharacters() {
        let line = "a   ==b"
        #expect(WordSelection.range(in: line, at: 1) == 1..<4)
        #expect(WordSelection.range(in: line, at: 4) == 4..<5)
        #expect(WordSelection.range(in: line, at: 5) == 5..<6)
        #expect(WordSelection.range(in: "", at: 0) == 0..<0)
    }

    @Test func wordSelectionKeepsComposedCharactersWhole() {
        #expect(WordSelection.range(in: "a😀b", at: 1) == 1..<3)
        let combining = "e\u{0301}f"
        #expect(WordSelection.range(in: combining, at: 0) == 0..<3)
    }

    // MARK: - Tab map inverse

    @Test func rawIndexInvertsTheTabMap() throws {
        let map = try #require(TabExpander.expand("a\tb", tabWidth: 4).map)
        #expect(map == [0, 1, 4, 5])
        #expect(TabExpander.rawIndex(forExpanded: 0, map: map) == 0)
        #expect(TabExpander.rawIndex(forExpanded: 1, map: map) == 1)
        #expect(TabExpander.rawIndex(forExpanded: 2, map: map) == 1)
        #expect(TabExpander.rawIndex(forExpanded: 3, map: map) == 2)
        #expect(TabExpander.rawIndex(forExpanded: 4, map: map) == 2)
        #expect(TabExpander.rawIndex(forExpanded: 5, map: map) == 3)
        #expect(TabExpander.rawIndex(forExpanded: 99, map: map) == 3)
    }

    @Test func rawIndexReturnsTheFirstUnitOfASurrogatePair() throws {
        let map = try #require(TabExpander.expand("\t😀", tabWidth: 4).map)
        #expect(map == [0, 4, 4, 6])
        #expect(TabExpander.rawIndex(forExpanded: 4, map: map) == 1)
        #expect(TabExpander.rawIndex(forExpanded: 0, map: map) == 0)
        #expect(TabExpander.rawIndex(forExpanded: 6, map: map) == 3)
    }

    // MARK: - Copied text

    @Test func textOfOneRowIsASubstring() {
        let selection = Self.selection(Self.position(1, 1), Self.position(1, 4))
        #expect(Self.newModel.text(in: selection) == "elt")
        #expect(Self.oldModel.text(in: selection) == "eta")
    }

    @Test func textJoinsRowsWithNewlines() {
        let selection = Self.selection(Self.position(0, 2), Self.position(3, 2))
        #expect(Self.newModel.text(in: selection) == "pha\ndelta\ninserted\nga")
    }

    @Test func padRowsContributeNothing() {
        let selection = Self.selection(Self.position(1, 0), Self.position(3, 5))
        #expect(Self.oldModel.text(in: selection) == "beta\ngamma")
    }

    @Test func selectionEndingAtTheNextRowKeepsTheTrailingNewline() {
        let selection = Self.selection(Self.position(1, 0), Self.position(2, 0))
        #expect(Self.newModel.text(in: selection) == "delta\n")
        #expect(Self.oldModel.text(in: selection) == "beta")
    }

    @Test func fullSelectionCoversEveryLine() throws {
        let whole = try #require(Self.newModel.fullSelection)
        #expect(Self.newModel.text(in: whole) == Self.newLines.joined(separator: "\n"))
        let wholeOld = try #require(Self.oldModel.fullSelection)
        #expect(Self.oldModel.text(in: wholeOld) == Self.oldLines.joined(separator: "\n"))
        #expect(PaneModel(side: .new, rows: [], lines: []).fullSelection == nil)
    }

    @Test func lineLengthIsZeroForPadRows() {
        #expect(Self.oldModel.lineLength(ofRow: 2) == 0)
        #expect(Self.newModel.lineLength(ofRow: 2) == 8)
        #expect(Self.newModel.lineLength(ofRow: 99) == 0)
    }
}
