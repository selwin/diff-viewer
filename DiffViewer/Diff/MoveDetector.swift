import Foundation

/// A block of lines cut from one place in a file and pasted in another. Lines match 1:1
/// in order, so both line ranges have the same length. A row range runs from the row of
/// the first matched line to the row of the last and may include padding or unrelated
/// rows, so anything drawn from it should go by line index.
struct DiffMove: Sendable, Equatable {
    let oldLineRange: Range<Int>
    let newLineRange: Range<Int>
    let oldRowRange: Range<Int>
    let newRowRange: Range<Int>
}

/// Finds moved blocks among a diff's changed lines, in the spirit of `git diff
/// --color-moved`: runs of consecutive lines removed in one place and added in another.
/// Lines match after trimming ASCII whitespace at both ends, or after removing all ASCII
/// whitespace when Hide Whitespace is on.
enum MoveDetector {
    /// A line this common among added lines (`}`, `return`) never starts a run, which keeps
    /// the search from pairing every brace with every other; it can still extend one.
    static let maxStartOccurrences = 64
    /// git's bar for --color-moved: smaller blocks are too likely to match by accident.
    static let minAlphanumerics = 20

    static func detect(
        oldLines: [String], newLines: [String], rows: [DiffRow], hideWhitespace: Bool
    ) -> [DiffMove] {
        let old = Side(lines: oldLines, rows: rows, cell: \.old, hideWhitespace: hideWhitespace)
        let new = Side(lines: newLines, rows: rows, cell: \.new, hideWhitespace: hideWhitespace)

        func makeRun(old i: Int, new j: Int, length: Int) -> Run {
            Run(old: i, new: j, length: length, alphanumerics: old.alphanumerics[i..<(i + length)].reduce(0, +))
        }

        func qualifies(_ run: Run) -> Bool { run.alphanumerics >= minAlphanumerics }

        var heap = RunHeap()
        for run in candidateRuns(old: old, new: new, makeRun: makeRun) where qualifies(run) {
            heap.push(run)
        }

        // Largest first, so a block pasted twice matches one destination. A run that
        // overlaps accepted lines keeps its free stretches as smaller runs.
        var usedOld = [Bool](repeating: false, count: oldLines.count)
        var usedNew = [Bool](repeating: false, count: newLines.count)
        var moves: [DiffMove] = []
        while let run = heap.pop() {
            let free = (0..<run.length).map { !usedOld[run.old + $0] && !usedNew[run.new + $0] }
            if !free.contains(false) {
                for offset in 0..<run.length {
                    usedOld[run.old + offset] = true
                    usedNew[run.new + offset] = true
                }
                moves.append(
                    DiffMove(
                        oldLineRange: run.old..<(run.old + run.length),
                        newLineRange: run.new..<(run.new + run.length),
                        oldRowRange: old.rowOf[run.old]..<(old.rowOf[run.old + run.length - 1] + 1),
                        newRowRange: new.rowOf[run.new]..<(new.rowOf[run.new + run.length - 1] + 1)))
                continue
            }
            var offset = 0
            while offset < run.length {
                guard free[offset] else {
                    offset += 1
                    continue
                }
                let start = offset
                while offset < run.length, free[offset] { offset += 1 }
                let piece = makeRun(old: run.old + start, new: run.new + start, length: offset - start)
                if qualifies(piece) { heap.push(piece) }
            }
        }
        return moves.sorted { $0.oldLineRange.lowerBound < $1.oldLineRange.lowerBound }
    }

    /// Every maximal run of equal keys along a diagonal, started from lines that may start
    /// one. A pair whose lines share a row is already shown side by side, an in-place edit,
    /// so it neither starts nor extends a run. A start already covered by an earlier run is
    /// skipped, so each (old, new) pair is scanned at most once.
    private static func candidateRuns(
        old: Side, new: Side, makeRun: (_ old: Int, _ new: Int, _ length: Int) -> Run
    ) -> [Run] {
        var newLinesByKey: [String: [Int]] = [:]
        for (j, key) in new.keys.enumerated() {
            if let key { newLinesByKey[key, default: []].append(j) }
        }
        var scanned = Set<Pair>()
        var runs: [Run] = []
        for (i, key) in old.keys.enumerated() {
            guard let key, !key.isEmpty, let targets = newLinesByKey[key], targets.count <= maxStartOccurrences else {
                continue
            }
            for j in targets where old.rowOf[i] != new.rowOf[j] && !scanned.contains(Pair(old: i, new: j)) {
                var length = 0
                while i + length < old.keys.count, j + length < new.keys.count,
                    old.rowOf[i + length] != new.rowOf[j + length],
                    let next = old.keys[i + length], next == new.keys[j + length]
                {
                    scanned.insert(Pair(old: i + length, new: j + length))
                    length += 1
                }
                runs.append(makeRun(i, j, length))
            }
        }
        return runs
    }

    /// One side's lines as the detector sees them.
    private struct Side {
        /// The comparison key of each line in a non-equal row; nil for every other line.
        var keys: [String?]
        /// The row holding each line.
        var rowOf: [Int]
        /// Letters and digits per line, the measure of a run's size.
        var alphanumerics: [Int]

        init(lines: [String], rows: [DiffRow], cell: KeyPath<DiffRow, DiffSide?>, hideWhitespace: Bool) {
            keys = [String?](repeating: nil, count: lines.count)
            rowOf = [Int](repeating: -1, count: lines.count)
            alphanumerics = [Int](repeating: 0, count: lines.count)
            for (index, row) in rows.enumerated() {
                guard let side = row[keyPath: cell] else { continue }
                let line = side.lineIndex
                rowOf[line] = index
                guard row.kind != .equal else { continue }
                keys[line] = MoveDetector.key(lines[line], hideWhitespace: hideWhitespace)
                alphanumerics[line] = lines[line].count(where: { $0.isLetter || $0.isNumber })
            }
        }
    }

    /// Indentation never matters to a move; interior spacing matters unless whitespace is
    /// hidden, matching how the rows were aligned.
    private static func key(_ line: String, hideWhitespace: Bool) -> String {
        if hideWhitespace { return DiffAligner.key(line, true) }
        let scalars = line.unicodeScalars
        let isContent: (Unicode.Scalar) -> Bool = { !DiffAligner.asciiWhitespace.contains($0) }
        guard let first = scalars.firstIndex(where: isContent), let last = scalars.lastIndex(where: isContent)
        else { return "" }
        return String(scalars[first...last])
    }

    private struct Pair: Hashable {
        let old: Int
        let new: Int
    }

    /// `length` matched lines from `old` and `new` onward.
    private struct Run {
        let old: Int
        let new: Int
        let length: Int
        let alphanumerics: Int

        /// Bigger first; ties go to the earlier old line, then the earlier new line, so the
        /// result never depends on heap order.
        func outranks(_ other: Run) -> Bool {
            if alphanumerics != other.alphanumerics { return alphanumerics > other.alphanumerics }
            if old != other.old { return old < other.old }
            return new < other.new
        }
    }

    /// A binary max-heap of runs; the standard library has none.
    private struct RunHeap {
        private var items: [Run] = []

        mutating func push(_ run: Run) {
            items.append(run)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].outranks(items[parent]) else { return }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> Run? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let top = items.removeLast()
            var parent = 0
            while true {
                var best = parent
                for child in [2 * parent + 1, 2 * parent + 2]
                where child < items.count && items[child].outranks(items[best]) {
                    best = child
                }
                if best == parent { break }
                items.swapAt(parent, best)
                parent = best
            }
            return top
        }
    }
}
