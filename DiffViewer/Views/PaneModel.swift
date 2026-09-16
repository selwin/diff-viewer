import Foundation

/// The document content one pane draws from. A changeset also carries its sections, so
/// the pane can show file-local line numbers instead of numbers into the flat document.
struct PaneModel {
    enum Side { case old, new }

    let side: Side
    let rows: [DiffRow]
    let lines: [String]
    /// Empty for a single file. Every section is kept so a header row can read its file;
    /// only the ones with rows take part in the line-number lookup.
    let sections: [ChangesetSection]
    /// Sections with a non-empty `rowRange`, in row order, for the binary search.
    private let rowSections: [ChangesetSection]

    init(side: Side, rows: [DiffRow], lines: [String], sections: [ChangesetSection] = []) {
        self.side = side
        self.rows = rows
        self.lines = lines
        self.sections = sections
        rowSections = sections.filter { !$0.rowRange.isEmpty }
    }

    func cell(_ row: DiffRow) -> DiffSide? {
        side == .old ? row.old : row.new
    }

    /// The section whose `rowRange` contains `row`: the last non-empty section starting
    /// at or before it, then a containment check, so an empty section sharing the same
    /// boundary is never chosen and a row outside every section returns nil.
    func section(containingRow row: Int) -> ChangesetSection? {
        var low = 0
        var high = rowSections.count - 1
        var candidate: Int?
        while low <= high {
            let mid = (low + high) / 2
            if rowSections[mid].rowRange.lowerBound <= row {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let candidate, rowSections[candidate].rowRange.contains(row) else { return nil }
        return rowSections[candidate]
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
        let widest = rowSections.lazy.map { side == .old ? $0.oldLineCount : $0.newLineCount }.max() ?? 0
        return max(4, String(max(widest, 1)).count)
    }
}
