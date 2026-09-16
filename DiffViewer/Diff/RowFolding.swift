import Foundation

/// One row of the side-by-side view after folding: a document row, a separator standing
/// in for a run of hidden (equal) document rows, or a synthetic row that belongs to a
/// changeset section rather than to the document. Synthetic rows carry the index of
/// their `ChangesetSection`; everything they show is read from that section.
enum DisplayRow: Equatable, Sendable {
    case documentRow(Int)
    /// `hidden` is a non-empty range of `DiffDocument.rows` indices.
    case separator(hidden: Range<Int>)
    case fileHeader(section: Int)
    case spacer(section: Int)
    /// A one-line explanation for a section with no rows ("Binary file", an error, …).
    case notice(section: Int)

    /// The document rows this display row stands for; nil for a synthetic row.
    var documentRows: Range<Int>? {
        switch self {
        case let .documentRow(index): index..<(index + 1)
        case let .separator(hidden): hidden
        case .fileHeader, .spacer, .notice: nil
        }
    }
}

/// Tunables for folding. Context lines may come from user defaults; use `validated`.
struct FoldOptions: Sendable {
    /// Equal rows kept visible on each side of a change block.
    var contextLines = 5
    /// Rows revealed by one expand-up / expand-down click.
    var expansionStep = 20
    /// A separator costs a row; hiding fewer rows than this is not worth a click.
    var minimumHiddenRun = 4

    static let contextLinesRange = 0...200

    /// Normalizes a possibly user-supplied context value.
    static func validated(contextLines: Int?) -> FoldOptions {
        var options = FoldOptions()
        if let contextLines {
            options.contextLines = min(max(contextLines, contextLinesRange.lowerBound), contextLinesRange.upperBound)
        }
        return options
    }
}

/// Which document rows the user has revealed in one file. Row indices only make sense
/// for the document they were created against.
struct FoldState: Sendable {
    var revealedDocumentRows = IndexSet()

    /// Extends the hunk above `hidden` downward by up to `step` rows.
    mutating func expandDown(_ hidden: Range<Int>, step: Int) {
        let upper = min(hidden.upperBound, hidden.lowerBound + step)
        revealedDocumentRows.insert(integersIn: hidden.lowerBound..<upper)
    }

    /// Extends the hunk below `hidden` upward by up to `step` rows.
    mutating func expandUp(_ hidden: Range<Int>, step: Int) {
        let lower = max(hidden.lowerBound, hidden.upperBound - step)
        revealedDocumentRows.insert(integersIn: lower..<hidden.upperBound)
    }

    mutating func expandRun(_ hidden: Range<Int>) {
        revealedDocumentRows.insert(integersIn: hidden)
    }

    mutating func expandAll(documentRowCount: Int) {
        revealedDocumentRows.insert(integersIn: 0..<documentRowCount)
    }
}

/// The folded projection of a document plus O(1) translations between document row
/// indices and display row indices.
struct FoldedRows: Sendable {
    let displayRows: [DisplayRow]
    let documentRowCount: Int
    /// For every document row, the display index that shows it or its separator.
    private let displayIndexByRow: [Int]
    /// For every synthetic display row, the document row it is inserted before.
    private let boundaryByDisplayIndex: [Int: Int]

    /// `syntheticBoundaries` holds one insertion boundary per synthetic display row, in
    /// display order. The single-file path emits no synthetic rows and passes none.
    init(displayRows: [DisplayRow], documentRowCount: Int, syntheticBoundaries: [Int] = []) {
        self.displayRows = displayRows
        self.documentRowCount = documentRowCount
        var table = Array(repeating: 0, count: documentRowCount)
        var boundaries: [Int: Int] = [:]
        var pending = syntheticBoundaries.makeIterator()
        for (index, row) in displayRows.enumerated() {
            switch row {
            case let .documentRow(i): table[i] = index
            case let .separator(hidden): for i in hidden { table[i] = index }
            case .fileHeader, .spacer, .notice:
                guard let boundary = pending.next() else {
                    preconditionFailure("every synthetic display row needs a boundary")
                }
                boundaries[index] = boundary
            }
        }
        precondition(pending.next() == nil, "more boundaries than synthetic display rows")
        displayIndexByRow = table
        boundaryByDisplayIndex = boundaries
    }

    static func identity(documentRowCount: Int) -> FoldedRows {
        FoldedRows(displayRows: (0..<documentRowCount).map { .documentRow($0) }, documentRowCount: documentRowCount)
    }

    /// Precondition: `0 <= row < documentRowCount`.
    func displayIndex(forDocumentRow row: Int) -> Int { displayIndexByRow[row] }

    /// Precondition: `0 <= index < displayRows.count`. A separator maps to its first
    /// hidden row. A synthetic row maps to its section's insertion boundary, which may
    /// equal `documentRowCount` and must never be used to index `DiffDocument.rows`.
    func documentRow(forDisplayIndex index: Int) -> Int {
        switch displayRows[index] {
        case let .documentRow(i): return i
        case let .separator(hidden): return hidden.lowerBound
        case .fileHeader, .spacer, .notice:
            guard let boundary = boundaryByDisplayIndex[index] else {
                preconditionFailure("synthetic display row \(index) has no boundary")
            }
            return boundary
        }
    }

    /// Half-open; empty ranges stay empty at the corresponding position.
    func displayRange(forDocumentRange range: Range<Int>) -> Range<Int> {
        guard !range.isEmpty else {
            let start =
                range.lowerBound < documentRowCount ? displayIndex(forDocumentRow: range.lowerBound) : displayRows.count
            return start..<start
        }
        let first = displayIndex(forDocumentRow: range.lowerBound)
        let last = displayIndex(forDocumentRow: range.upperBound - 1)
        return first..<(last + 1)
    }

    /// Half-open; a trailing separator contributes all of its hidden rows. Synthetic rows
    /// stand for no document rows, so the end comes from the last row in the range that
    /// does; a range holding only synthetic rows is empty at the boundary of its first row.
    func documentRange(forDisplayRange range: Range<Int>) -> Range<Int> {
        guard !range.isEmpty else {
            let start =
                range.lowerBound < displayRows.count ? documentRow(forDisplayIndex: range.lowerBound) : documentRowCount
            return start..<start
        }
        let first = documentRow(forDisplayIndex: range.lowerBound)
        guard let end = range.reversed().lazy.compactMap({ displayRows[$0].documentRows?.upperBound }).first else {
            return first..<first
        }
        precondition(end >= first, "display rows map to document rows out of order")
        return first..<end
    }
}

/// Controls shown on a separator, in left-to-right order.
enum FoldControl: Equatable, Sendable {
    /// Reveal the last `expansionStep` hidden rows (extends the hunk below upward).
    case expandUp
    /// Reveal the first `expansionStep` hidden rows (extends the hunk above downward).
    case expandDown
    /// Reveal the whole run (shown alone when the run fits in one step).
    case expandRun
}

enum RowFolding {
    /// Hides equal rows outside `contextLines` of every change block, except rows the
    /// user revealed and gaps too small to be worth a separator. A document with no
    /// change blocks is shown in full.
    static func fold(changeBlocks: [Range<Int>], documentRowCount: Int, state: FoldState, options: FoldOptions)
        -> FoldedRows
    {
        guard !changeBlocks.isEmpty, documentRowCount > 0 else {
            return .identity(documentRowCount: documentRowCount)
        }
        var visible = IndexSet()
        for block in changeBlocks {
            let lower = max(0, block.lowerBound - options.contextLines)
            let upper = min(documentRowCount, block.upperBound + options.contextLines)
            if lower < upper { visible.insert(integersIn: lower..<upper) }
        }
        visible.formUnion(state.revealedDocumentRows.intersection(IndexSet(integersIn: 0..<documentRowCount)))

        var rows: [DisplayRow] = []
        rows.reserveCapacity(documentRowCount)
        func emitGap(_ gap: Range<Int>) {
            if gap.count < options.minimumHiddenRun {
                for i in gap { rows.append(.documentRow(i)) }
            } else {
                rows.append(.separator(hidden: gap))
            }
        }
        var cursor = 0
        for range in visible.rangeView {
            if cursor < range.lowerBound { emitGap(cursor..<range.lowerBound) }
            for i in range { rows.append(.documentRow(i)) }
            cursor = range.upperBound
        }
        if cursor < documentRowCount { emitGap(cursor..<documentRowCount) }
        return FoldedRows(displayRows: rows, documentRowCount: documentRowCount)
    }

    static func controls(for hidden: Range<Int>, documentRowCount: Int, options: FoldOptions) -> [FoldControl] {
        if hidden.count <= options.expansionStep { return [.expandRun] }
        if hidden.lowerBound == 0 { return [.expandUp] }
        if hidden.upperBound == documentRowCount { return [.expandDown] }
        return [.expandUp, .expandDown]
    }
}
