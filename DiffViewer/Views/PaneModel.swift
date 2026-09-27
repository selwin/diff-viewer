import Foundation

/// The document content one pane draws from. A changeset also carries its sections, so
/// the pane can show file-local line numbers instead of numbers into the flat document.
struct PaneModel {
    typealias Side = DocumentSide

    let side: Side
    let rows: [DiffRow]
    let lines: [String]
    /// Empty for a single file. Every section is kept so a header row can read its file;
    /// only the ones with rows take part in the line-number lookup.
    let sections: [ChangesetSection]
    /// Row → section lookup over `sections`. A changeset passes the one its document
    /// already built; otherwise one is built here.
    private let sectionIndex: SectionIndex
    /// The document's moves, in document coordinates.
    let moves: [DiffMove]
    /// This side's moved line index → index into `moves`. Rebuilt with the model, so an
    /// appended changeset covers its new sections too.
    private let moveIndexByLine: [Int: Int]

    init(
        side: Side, rows: [DiffRow], lines: [String], sections: [ChangesetSection] = [],
        sectionIndex: SectionIndex? = nil, moves: [DiffMove] = []
    ) {
        self.side = side
        self.rows = rows
        self.lines = lines
        self.sections = sections
        self.sectionIndex = sectionIndex ?? SectionIndex(sections: sections)
        self.moves = moves
        self.moveIndexByLine = Self.moveIndexByLine(moves, side: side)
    }

    /// Maps every line a move covers on `side` to that move's index.
    static func moveIndexByLine(_ moves: [DiffMove], side: Side) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (index, move) in moves.enumerated() {
            for line in side == .old ? move.oldLineRange : move.newLineRange { map[line] = index }
        }
        return map
    }

    func cell(_ row: DiffRow) -> DiffSide? {
        side == .old ? row.old : row.new
    }

    /// The section whose `rowRange` contains `row`; nil for a row outside every section.
    func section(containingRow row: Int) -> ChangesetSection? {
        sectionIndex.sectionIndex(containingRow: row).map { sections[$0] }
    }

    /// Whether this side's `line` was moved; a moved line is tinted by line, never by row,
    /// because a move's row range can include unrelated rows.
    func isMoved(line: Int) -> Bool {
        moveIndexByLine[line] != nil
    }

    /// The gutter marker for `line`, which only the first line of a moved run carries.
    func moveMarker(forLine line: Int) -> MoveMarker? {
        guard let index = moveIndexByLine[line] else { return nil }
        let move = moves[index]
        let (lineRange, rowRange, partnerRowRange) =
            side == .old
            ? (move.oldLineRange, move.oldRowRange, move.newRowRange)
            : (move.newLineRange, move.newRowRange, move.oldRowRange)
        guard line == lineRange.lowerBound else { return nil }
        return MoveMarker(
            partnerRow: partnerRowRange.lowerBound, pointsUp: partnerRowRange.lowerBound < rowRange.lowerBound)
    }

    /// The number to show for `cell` in `row`: file-local inside a changeset section,
    /// the global line number when there are no sections.
    func lineNumber(of cell: DiffSide, inRow row: Int) -> Int {
        guard let section = section(containingRow: row) else { return cell.lineNumber }
        let offset = side == .old ? section.oldLineOffset : section.newLineOffset
        return cell.lineIndex - offset + 1
    }

    /// Digits the gutter must fit. A changeset keeps a little slack (4) because later
    /// sections arrive after the width is set and the gutter only ever widens; a changeset
    /// whose sections have no rows yet still uses that minimum, so the gutter does not jump
    /// when the first text section arrives.
    var gutterDigits: Int {
        guard !sections.isEmpty else { return max(3, String(max(lines.count, 1)).count) }
        let widest =
            sections.lazy.filter { !$0.rowRange.isEmpty }
            .map { side == .old ? $0.oldLineCount : $0.newLineCount }.max() ?? 0
        return max(4, String(max(widest, 1)).count)
    }
}

/// The chevron beside the first line of a moved run. A pair of lines on one row never
/// starts a move, so the two ends never share a row and the direction is never a tie.
struct MoveMarker: Equatable {
    /// The other side's first document row of the move; clicking the marker jumps there.
    let partnerRow: Int
    let pointsUp: Bool
}
