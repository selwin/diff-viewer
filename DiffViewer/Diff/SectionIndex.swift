import Foundation

/// Row → section lookup for a changeset, built once from its sections. Only sections
/// with a non-empty `rowRange` take part; the answer is the section's index in the
/// original array, so a caller can read its file from there.
struct SectionIndex: Sendable, Equatable {
    /// Original indices of the sections with rows, in row order.
    private let indices: [Int]
    /// The row ranges of those sections, parallel to `indices`.
    private let ranges: [Range<Int>]

    init(sections: [ChangesetSection]) {
        var indices: [Int] = []
        var ranges: [Range<Int>] = []
        for (index, section) in sections.enumerated() where !section.rowRange.isEmpty {
            indices.append(index)
            ranges.append(section.rowRange)
        }
        self.indices = indices
        self.ranges = ranges
    }

    /// The original index of the section whose `rowRange` contains `row`: the last
    /// non-empty section starting at or before it, then a containment check, so an empty
    /// section sharing the same boundary is never chosen and a row outside every section
    /// (a gap, or past the end) returns nil.
    func sectionIndex(containingRow row: Int) -> Int? {
        var low = 0
        var high = ranges.count - 1
        var candidate: Int?
        while low <= high {
            let mid = (low + high) / 2
            if ranges[mid].lowerBound <= row {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let candidate, ranges[candidate].contains(row) else { return nil }
        return indices[candidate]
    }

    /// The section the display row at `index` belongs to. Synthetic rows carry their
    /// section (a spacer belongs to the file that follows it); a document row or
    /// separator is looked up by the document row it stands for.
    func sectionIndex(containingDisplayIndex index: Int, in folded: FoldedRows) -> Int? {
        switch folded.displayRows[index] {
        case let .fileHeader(section), let .spacer(section), let .notice(section):
            return section
        case .documentRow, .separator:
            return sectionIndex(containingRow: folded.documentRow(forDisplayIndex: index))
        }
    }
}
