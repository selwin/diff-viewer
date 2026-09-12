import Foundation

/// One side (old or new) of an aligned diff row.
struct DiffSide: Sendable, Equatable {
    /// 0-based index into the side's line array.
    let lineIndex: Int
    /// UTF-16 ranges within the line that changed (token-level, from difftastic,
    /// or a prefix/suffix estimate for whitespace-only changes).
    var highlights: [Range<Int>]

    var lineNumber: Int { lineIndex + 1 }
}

/// One horizontal row of the side-by-side view. A nil side is a padding cell.
struct DiffRow: Sendable, Equatable {
    enum Kind: Sendable {
        case equal
        case modified
        case added
        case deleted
    }

    let kind: Kind
    let old: DiffSide?
    let new: DiffSide?

    static func equal(old: Int, new: Int) -> DiffRow {
        DiffRow(kind: .equal, old: DiffSide(lineIndex: old, highlights: []), new: DiffSide(lineIndex: new, highlights: []))
    }
}

/// The fully computed diff for one file: both texts split into lines, aligned rows,
/// and the row ranges that contain changes (for next/previous navigation).
struct DiffDocument: Sendable {
    let oldLines: [String]
    let newLines: [String]
    let rows: [DiffRow]
    /// Language name reported by difftastic (e.g. "Swift", "Text"), if it ran.
    let language: String?
    /// Consecutive runs of non-equal rows.
    let changeBlocks: [Range<Int>]

    init(oldLines: [String], newLines: [String], rows: [DiffRow], language: String?) {
        self.oldLines = oldLines
        self.newLines = newLines
        self.rows = rows
        self.language = language
        self.changeBlocks = Self.computeChangeBlocks(rows)
    }

    static func empty() -> DiffDocument {
        DiffDocument(oldLines: [], newLines: [], rows: [], language: nil)
    }

    private static func computeChangeBlocks(_ rows: [DiffRow]) -> [Range<Int>] {
        var blocks: [Range<Int>] = []
        var start: Int?
        for (index, row) in rows.enumerated() {
            if row.kind == .equal {
                if let s = start { blocks.append(s..<index); start = nil }
            } else if start == nil {
                start = index
            }
        }
        if let s = start { blocks.append(s..<rows.count) }
        return blocks
    }
}

/// What the detail area shows for a selected file.
enum DiffContent: Sendable {
    case text(DiffDocument)
    case binary
    case identical
}

enum TextLines {
    /// Splits text into lines on "\n", dropping the trailing empty line produced by a
    /// final newline. A trailing "\r" is kept so CRLF changes remain visible.
    static func split(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
