import AppKit
import CoreText
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

    private static let oldModel = PaneModel(side: .old, rows: rows, lines: oldLines, changeBlocks: [])
    private static let newModel = PaneModel(side: .new, rows: rows, lines: newLines, changeBlocks: [])

    private static func position(_ row: Int, _ offset: Int) -> TextPosition {
        TextPosition(row: row, offset: offset)
    }

    private static func selection(_ start: TextPosition, _ end: TextPosition) -> PaneSelection {
        PaneSelection(anchor: start, head: end)
    }

    @Test func oneRowSelectionRoundTripsItsRange() {
        #expect(PaneSelection(row: 3, range: 2..<7).singleRowRange == 2..<7)
        let acrossRows = Self.selection(Self.position(1, 2), Self.position(2, 1))
        #expect(acrossRows.singleRowRange == nil)
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

    @Test func expandedIndexFollowsTheTabMap() {
        let map = TabExpander.expand("a\tb", tabWidth: 4).map
        #expect(TabExpander.expandedIndex(forRaw: 3, map: nil) == 3)
        #expect(TabExpander.expandedIndex(forRaw: 2, map: map) == 4)
        #expect(TabExpander.expandedIndex(forRaw: 99, map: map) == 5)
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
        #expect(PaneModel(side: .new, rows: [], lines: [], changeBlocks: []).fullSelection == nil)
    }

    @Test func lineLengthIsZeroForPadRows() {
        #expect(Self.oldModel.lineLength(ofRow: 2) == 0)
        #expect(Self.newModel.lineLength(ofRow: 2) == 8)
        #expect(Self.newModel.lineLength(ofRow: 99) == 0)
    }

    @Test func fileNameSelectionRangeAndText() {
        #expect(FileNameSelection(section: 0, anchor: 5, head: 2).range == 2..<5)
        // An offset inside the emoji's surrogate pair still copies the whole emoji.
        let name = "a😀b"
        #expect(FileNameSelection(section: 0, anchor: 0, head: 2).text(in: name) == "a😀")
        #expect(FileNameSelection(section: 0, anchor: 1, head: 99).text(in: name) == "😀b")
        #expect(FileNameSelection(section: 0, anchor: 8, head: 9).text(in: name) == "")
    }

    /// What the two geometry helpers answer for a name, computed up front because a
    /// `CTLine` is not `Sendable` and so cannot appear inside `#expect`.
    @MainActor
    private struct NameGeometry {
        let width: CGFloat
        let xs: [CGFloat]
        let offsetBefore: Int
        let offsetPast: Int
        let offsetAtThreeChars: Int

        init(_ string: String, widthFraction: Double = 1, charAdvance: CGFloat = 0) throws {
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let full = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
            let target = CTLineGetTypographicBounds(full, nil, nil, nil) * widthFraction
            let line = widthFraction == 1 ? full : try #require(CTLineCreateTruncatedLine(full, target, .end, token))
            let length = string.utf16.count
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            self.width = width
            xs = (0...length).map { DiffPaneView.fileNameX(forOffset: $0, line: line, length: length) }
            offsetBefore = DiffPaneView.fileNameOffset(forX: -3, line: line, length: length)
            offsetPast = DiffPaneView.fileNameOffset(forX: width + 3, line: line, length: length)
            offsetAtThreeChars = DiffPaneView.fileNameOffset(forX: charAdvance * 3.2, line: line, length: length)
        }
    }

    @Test @MainActor func fileNameGeometryOnATruncatedLine() throws {
        let string = "averyveryverylongfilename.swift"
        let advance = try NameGeometry("a").width
        let name = try NameGeometry(string, widthFraction: 0.5, charAdvance: advance)
        let length = string.utf16.count
        #expect(name.offsetBefore == 0)
        #expect(name.offsetAtThreeChars == 3)
        #expect(name.offsetPast == length)
        #expect(abs(name.xs[3] - advance * 3) < 0.01)
        // Text the ellipsis cut off, and the end itself, reach the ellipsis' far edge.
        #expect(name.xs[length - 1] == name.width)
        #expect(name.xs[length] == name.width)
    }

    @Test @MainActor func fileNameGeometryFollowsTextDirection() throws {
        let hebrew = "שלוםעולםשלום"
        let length = hebrew.utf16.count
        let name = try NameGeometry(hebrew)
        #expect(name.xs[0] == name.width)
        #expect(name.xs[length] == 0)
        #expect(name.offsetBefore == length)
        #expect(name.offsetPast == 0)

        // Truncated, the ellipsis sits at the left, so cut text reaches x = 0.
        let cut = try NameGeometry(hebrew, widthFraction: 0.5)
        #expect(cut.xs[0] == cut.width)
        #expect(cut.xs[length - 1] == 0)

        // ".swift" is drawn first, so offset 5, its first character after the dot, is a real x = 0.
        #expect(try NameGeometry("שלום.swift").xs[5] == 0)
    }

    @Test @MainActor func fileNameAndTextSelectionsAreExclusiveAndSelectAllStaysInTheName() {
        let section = ChangesetSection(
            file: changedFile("Sources/name.swift"), rowRange: 0..<0, oldLineOffset: 0, newLineOffset: 0,
            oldLineCount: 0, newLineCount: 0, added: 0, deleted: 0, outcome: .binary)
        let model = PaneModel(side: .old, rows: [], lines: [], sections: [section], changeBlocks: [])
        let pane = DiffPaneView(frame: .zero)
        pane.install(model, mode: .replace)

        pane.fileNameSelection = FileNameSelection(section: 0, anchor: 1, head: 2)
        pane.selectAll(nil)
        #expect(pane.selectedFileNameText() == "name.swift")

        pane.selection = PaneSelection(row: 0, range: 0..<1)
        #expect(pane.fileNameSelection == nil)
        pane.fileNameSelection = FileNameSelection(section: 0, anchor: 0, head: 1)
        #expect(pane.selection == nil)

        pane.install(model, mode: .append)
        #expect(pane.fileNameSelection != nil)
        pane.install(model, mode: .replace)
        #expect(pane.fileNameSelection == nil)
    }
}
