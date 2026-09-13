import Foundation

/// Turns two line arrays into side-by-side rows. Line alignment comes from a
/// Myers diff over (optionally whitespace-normalized) lines; difftastic hints
/// refine which changed lines sit next to each other and which tokens light up.
enum DiffAligner {
    static func align(
        oldLines: [String],
        newLines: [String],
        hideWhitespace: Bool,
        hints: DifftHints
    ) -> [DiffRow] {
        let ops = LineDiff.diff(oldLines.map { key($0, hideWhitespace) }, newLines.map { key($0, hideWhitespace) })

        var rows: [DiffRow] = []
        rows.reserveCapacity(ops.count)
        var pendingDeletes: [Int] = []
        var pendingInserts: [Int] = []

        func side(old index: Int) -> DiffSide {
            DiffSide(lineIndex: index, highlights: utf16Ranges(hints.oldChanges[index] ?? [], in: oldLines[index]))
        }
        func side(new index: Int) -> DiffSide {
            DiffSide(lineIndex: index, highlights: utf16Ranges(hints.newChanges[index] ?? [], in: newLines[index]))
        }

        /// Emits a modified/added/deleted row, adding prefix/suffix highlights when
        /// difftastic had nothing to say about a pair of textually different lines.
        func emit(old: Int?, new: Int?) {
            var oldSide = old.map(side(old:))
            var newSide = new.map(side(new:))
            let kind: DiffRow.Kind
            switch (oldSide, newSide) {
            case (.some, .some):
                kind = .modified
                if oldSide!.highlights.isEmpty, newSide!.highlights.isEmpty {
                    let (o, n) = prefixSuffixHighlights(oldLines[old!], newLines[new!])
                    oldSide!.highlights = o
                    newSide!.highlights = n
                }
            case (.some, .none):
                kind = .deleted
            case (.none, .some):
                kind = .added
            case (.none, .none):
                return
            }
            rows.append(DiffRow(kind: kind, old: oldSide, new: newSide))
        }

        func zip(_ deletes: ArraySlice<Int>, _ inserts: ArraySlice<Int>) {
            let count = max(deletes.count, inserts.count)
            for i in 0..<count {
                let o = i < deletes.count ? deletes[deletes.startIndex + i] : nil
                let n = i < inserts.count ? inserts[inserts.startIndex + i] : nil
                emit(old: o, new: n)
            }
        }

        func flush() {
            defer { pendingDeletes.removeAll(keepingCapacity: true); pendingInserts.removeAll(keepingCapacity: true) }
            guard !pendingDeletes.isEmpty || !pendingInserts.isEmpty else { return }
            let deleteSet = Set(pendingDeletes)
            let insertSet = Set(pendingInserts)
            // Monotonic subset of difftastic pairs that fall inside this block.
            var pairs: [(old: Int, new: Int)] = []
            var lastNew = -1
            for pair in hints.pairs where deleteSet.contains(pair.old) && insertSet.contains(pair.new) {
                if pair.new > lastNew, pairs.last.map { pair.old > $0.old } ?? true {
                    pairs.append(pair)
                    lastNew = pair.new
                }
            }
            var di = pendingDeletes.startIndex
            var ii = pendingInserts.startIndex
            for pair in pairs {
                let dEnd = pendingDeletes.firstIndex(of: pair.old)!
                let iEnd = pendingInserts.firstIndex(of: pair.new)!
                zip(pendingDeletes[di..<dEnd], pendingInserts[ii..<iEnd])
                emit(old: pair.old, new: pair.new)
                di = dEnd + 1
                ii = iEnd + 1
            }
            zip(pendingDeletes[di...], pendingInserts[ii...])
        }

        for op in ops {
            switch op {
            case let .equal(o, n):
                flush()
                let oldSide = side(old: o)
                let newSide = side(new: n)
                if oldSide.highlights.isEmpty, newSide.highlights.isEmpty {
                    rows.append(DiffRow(kind: .equal, old: oldSide, new: newSide))
                } else {
                    rows.append(DiffRow(kind: .modified, old: oldSide, new: newSide))
                }
            case let .delete(o):
                pendingDeletes.append(o)
            case let .insert(n):
                pendingInserts.append(n)
            }
        }
        flush()
        return rows
    }

    /// The comparison key for a line. With whitespace hidden, all whitespace is
    /// dropped so indentation and spacing differences align as equal lines.
    static func key(_ line: String, _ hideWhitespace: Bool) -> String {
        guard hideWhitespace else { return line }
        return String(line.unicodeScalars.filter { !$0.properties.isWhitespace })
    }

    /// Converts UTF-8 byte ranges from difftastic into UTF-16 ranges, merging overlaps.
    static func utf16Ranges(_ byteRanges: [Range<Int>], in line: String) -> [Range<Int>] {
        guard !byteRanges.isEmpty else { return [] }
        let utf8 = line.utf8
        let utf16 = line.utf16
        let byteCount = utf8.count
        var result: [Range<Int>] = []
        for range in byteRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lower = min(max(range.lowerBound, 0), byteCount)
            let upper = min(max(range.upperBound, lower), byteCount)
            guard upper > lower else { continue }
            let startIndex = utf8.index(utf8.startIndex, offsetBy: lower)
            let endIndex = utf8.index(utf8.startIndex, offsetBy: upper)
            let s = utf16.distance(from: utf16.startIndex, to: startIndex)
            let e = utf16.distance(from: utf16.startIndex, to: endIndex)
            guard e > s else { continue }
            if let last = result.last, s <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, e)
            } else {
                result.append(s..<e)
            }
        }
        return result
    }

    /// Highlights the differing middle of two lines (UTF-16 offsets) by trimming a
    /// common prefix and suffix.
    static func prefixSuffixHighlights(_ old: String, _ new: String) -> ([Range<Int>], [Range<Int>]) {
        let o = Array(old.utf16)
        let n = Array(new.utf16)
        var prefix = 0
        while prefix < o.count, prefix < n.count, o[prefix] == n[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < o.count - prefix, suffix < n.count - prefix, o[o.count - 1 - suffix] == n[n.count - 1 - suffix] {
            suffix += 1
        }
        let oRange = prefix..<(o.count - suffix)
        let nRange = prefix..<(n.count - suffix)
        return (oRange.isEmpty ? [] : [oRange], nRange.isEmpty ? [] : [nRange])
    }
}
