import Foundation

/// A caret position in one pane: a document row plus a UTF-16 offset into that row's
/// raw (tab-unexpanded) line. Positions survive folding, font changes and style
/// arrival because they never refer to display rows or expanded columns.
struct TextPosition: Comparable, Sendable {
    var row: Int
    var offset: Int

    static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        lhs.row == rhs.row ? lhs.offset < rhs.offset : lhs.row < rhs.row
    }
}

/// A text selection in one pane. `anchor` is where the drag started and `head` where
/// it is now, so either may be the earlier position.
struct PaneSelection: Equatable, Sendable {
    var anchor: TextPosition
    var head: TextPosition

    var start: TextPosition { min(anchor, head) }
    var end: TextPosition { max(anchor, head) }
    var isEmpty: Bool { anchor == head }

    /// The selected UTF-16 range within `row`, clamped to `lineLength`. Nil when the
    /// row lies outside the selection.
    func range(forRow row: Int, lineLength: Int) -> Range<Int>? {
        let start = start
        let end = end
        guard row >= start.row, row <= end.row else { return nil }
        func clamped(_ offset: Int) -> Int { min(max(offset, 0), lineLength) }
        let lower = row == start.row ? clamped(start.offset) : 0
        let upper = row == end.row ? clamped(end.offset) : lineLength
        return lower..<max(lower, upper)
    }

    /// Whether the selection continues past the end of `row`, i.e. the newline is selected.
    func includesLineEnd(ofRow row: Int) -> Bool { row < end.row }
}

/// The double-click word rule: letters, digits and `_` form a word; anything else is a
/// run of whitespace or a single character. Scanning `Character`s keeps emoji and
/// combining marks whole.
enum WordSelection {
    private enum Kind {
        case word
        case whitespace
        case single
    }

    private static func kind(of character: Character) -> Kind {
        if character.isLetter || character.isNumber || character == "_" { return .word }
        if character.isWhitespace { return .whitespace }
        return .single
    }

    /// The UTF-16 range to select for a double click at `offset` in `line`.
    static func range(in line: String, at offset: Int) -> Range<Int> {
        guard !line.isEmpty else { return 0..<0 }
        var spans: [(range: Range<Int>, kind: Kind)] = []
        for index in line.indices {
            let lower = index.utf16Offset(in: line)
            let upper = line.index(after: index).utf16Offset(in: line)
            spans.append((lower..<upper, kind(of: line[index])))
        }
        let target = min(max(offset, 0), line.utf16.count)
        // Past the last character (a click at the end of the line) uses the last one.
        let hit = spans.firstIndex { target < $0.range.upperBound } ?? spans.count - 1
        let kind = spans[hit].kind
        var lower = hit
        var upper = hit
        if kind != .single {
            while lower > 0, spans[lower - 1].kind == kind { lower -= 1 }
            while upper + 1 < spans.count, spans[upper + 1].kind == kind { upper += 1 }
        }
        return spans[lower].range.lowerBound..<spans[upper].range.upperBound
    }
}

extension TabExpander {
    /// Inverse of `expand`'s map: the raw UTF-16 index for an expanded column. An exact
    /// hit returns the first index of a duplicate run (a surrogate pair shares a column);
    /// otherwise the nearer neighbour, ties going to the higher index.
    static func rawIndex(forExpanded expanded: Int, map: [Int]) -> Int {
        guard let last = map.last else { return 0 }
        let target = min(max(expanded, 0), last)
        var low = 0
        var high = map.count - 1
        while low < high {
            let mid = (low + high) / 2
            if map[mid] < target { low = mid + 1 } else { high = mid }
        }
        guard low > 0, map[low] != target else { return low }
        return (target - map[low - 1]) < (map[low] - target) ? low - 1 : low
    }
}

extension PaneModel {
    /// UTF-16 length of the line this side shows for `row`; 0 for a pad row.
    func lineLength(ofRow row: Int) -> Int {
        guard rows.indices.contains(row), let cell = cell(rows[row]) else { return 0 }
        return lines[cell.lineIndex].utf16.count
    }

    /// A selection covering the whole document, or nil when there are no rows.
    var fullSelection: PaneSelection? {
        guard let last = rows.indices.last else { return nil }
        return PaneSelection(
            anchor: TextPosition(row: 0, offset: 0),
            head: TextPosition(row: last, offset: lineLength(ofRow: last)))
    }

    /// The selected text, rows joined with "\n". Rows hidden by a fold are included, so
    /// the clipboard holds a contiguous excerpt; pad rows contribute nothing at all.
    func text(in selection: PaneSelection) -> String {
        guard !rows.isEmpty else { return "" }
        let first = min(max(selection.start.row, 0), rows.count - 1)
        let last = min(max(selection.end.row, 0), rows.count - 1)
        guard first <= last else { return "" }
        var pieces: [String] = []
        for row in first...last {
            guard let cell = cell(rows[row]) else { continue }
            let line = lines[cell.lineIndex] as NSString
            guard let range = selection.range(forRow: row, lineLength: line.length) else { continue }
            if range.isEmpty {
                pieces.append("")
                continue
            }
            let rounded = line.rangeOfComposedCharacterSequences(
                for: NSRange(location: range.lowerBound, length: range.count))
            pieces.append(line.substring(with: rounded))
        }
        return pieces.joined(separator: "\n")
    }
}
