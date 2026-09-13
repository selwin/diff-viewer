import Foundation
import SwiftTreeSitter

/// Syntax highlighting for one side of a diff: parses the full text with tree-sitter,
/// runs the grammar's highlight query, and returns per-line style runs.
enum Highlighter {
    /// Texts above this size are left unhighlighted to keep things snappy.
    static let maxBytes = 4_000_000

    static func highlight(lines: [String], fileName: String) -> [[StyleRun]]? {
        guard !lines.isEmpty,
            let config = LanguageRegistry.configuration(forFileNamed: fileName),
            let query = config.queries[.highlights]
        else { return nil }

        let text = lines.joined(separator: "\n")
        guard text.utf8.count <= maxBytes else { return nil }

        let parser = Parser()
        do { try parser.setLanguage(config.language) } catch { return nil }
        guard let tree = parser.parse(text) else { return nil }

        // Collect captures as UTF-16 ranges, then paint in tree-sitter precedence order:
        // earlier start first, wider ranges before nested ones (so inner captures win),
        // and for identical ranges the pattern the grammar's spec prefers (normally the
        // later one, as in tree-sitter-highlight).
        let laterPatternWins = LanguageRegistry.spec(forFileNamed: fileName)?.precedence != .earlierPatternWins
        var captures: [(start: Int, end: Int, pattern: Int, style: TokenStyle)] = []
        let cursor = query.execute(in: tree)
        let context = Predicate.Context(string: text)
        while let match = cursor.nextMatch() {
            guard match.allowed(in: context) else { continue }
            for capture in match.captures {
                guard let name = capture.name,
                    let style = TokenStyle.paintStyle(forCaptureName: name)
                else { continue }
                let range = capture.range
                guard range.length > 0 else { continue }
                captures.append((range.location, range.location + range.length, match.patternIndex, style))
            }
        }
        guard !captures.isEmpty else { return Array(repeating: [], count: lines.count) }
        captures.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end > $1.end }
            return laterPatternWins ? $0.pattern > $1.pattern : $0.pattern < $1.pattern
        }

        var painter = LinePainter(lines: lines)
        var lastRange = (-1, -1)
        for capture in captures {
            if (capture.start, capture.end) == lastRange { continue }
            lastRange = (capture.start, capture.end)
            painter.paint(start: capture.start, end: capture.end, style: capture.style)
        }
        return painter.runs()
    }

    /// Per-line style buffers addressed by document-wide UTF-16 offsets.
    struct LinePainter {
        private let lineStarts: [Int]
        private let lineLengths: [Int]
        private var buffers: [[UInt8]?]

        init(lines: [String]) {
            var starts: [Int] = []
            var lengths: [Int] = []
            starts.reserveCapacity(lines.count)
            lengths.reserveCapacity(lines.count)
            var offset = 0
            for line in lines {
                let length = line.utf16.count
                starts.append(offset)
                lengths.append(length)
                offset += length + 1
            }
            lineStarts = starts
            lineLengths = lengths
            buffers = Array(repeating: nil, count: lines.count)
        }

        private func line(containing offset: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low
        }

        mutating func paint(start: Int, end: Int, style: TokenStyle) {
            guard !lineStarts.isEmpty, end > start else { return }
            var lineIndex = line(containing: start)
            var position = start
            while position < end, lineIndex < lineStarts.count {
                let lineStart = lineStarts[lineIndex]
                let lineEnd = lineStart + lineLengths[lineIndex]
                let from = max(position, lineStart)
                let to = min(end, lineEnd)
                if to > from {
                    if buffers[lineIndex] == nil {
                        buffers[lineIndex] = Array(repeating: 0, count: lineLengths[lineIndex])
                    }
                    for column in (from - lineStart)..<(to - lineStart) {
                        buffers[lineIndex]![column] = style.rawValue
                    }
                }
                position = lineEnd + 1
                lineIndex += 1
            }
        }

        func runs() -> [[StyleRun]] {
            buffers.map { buffer in
                guard let buffer else { return [] }
                var runs: [StyleRun] = []
                var index = 0
                while index < buffer.count {
                    let value = buffer[index]
                    var end = index + 1
                    while end < buffer.count, buffer[end] == value { end += 1 }
                    if value != 0, let style = TokenStyle(rawValue: value) {
                        runs.append(StyleRun(range: index..<end, style: style))
                    }
                    index = end
                }
                return runs
            }
        }
    }
}
