import Foundation

/// Folds a changeset into display rows: a spacer and a header before every section
/// (no spacer before the first), then each `.text` section folded on its own change
/// blocks, or one notice row for every other outcome. Folding per section is what keeps
/// a gap that straddles two files two separators rather than one.
enum ChangesetProjection {
    static func build(document changeset: ChangesetDocument, options: FoldOptions) -> FoldedRows {
        var displayRows: [DisplayRow] = []
        var boundaries: [Int] = []

        for (index, section) in changeset.sections.enumerated() {
            let boundary = section.rowRange.lowerBound
            if index > 0 {
                displayRows.append(.spacer(section: index))
                boundaries.append(boundary)
            }
            displayRows.append(.fileHeader(section: index))
            boundaries.append(boundary)

            guard case .text = section.outcome else {
                displayRows.append(.notice(section: index))
                boundaries.append(boundary)
                continue
            }

            let folded = RowFolding.fold(
                changeBlocks: localBlocks(changeset.document.changeBlocks, in: section.rowRange),
                documentRowCount: section.rowRange.count,
                state: FoldState(),
                options: options)
            for row in folded.displayRows {
                switch row {
                case let .documentRow(i):
                    displayRows.append(.documentRow(i + boundary))
                case let .separator(hidden):
                    displayRows.append(
                        .separator(hidden: (hidden.lowerBound + boundary)..<(hidden.upperBound + boundary)))
                case .fileHeader, .spacer, .notice:
                    preconditionFailure("RowFolding never emits synthetic rows")
                }
            }
        }

        return FoldedRows(
            displayRows: displayRows,
            documentRowCount: changeset.document.rows.count,
            syntheticBoundaries: boundaries)
    }

    /// The flat document's blocks clipped to one section and shifted to section-local
    /// indices. Blocks never span a section, so the clipping is defensive.
    private static func localBlocks(_ blocks: [Range<Int>], in range: Range<Int>) -> [Range<Int>] {
        blocks.compactMap { block in
            let lower = max(block.lowerBound, range.lowerBound)
            let upper = min(block.upperBound, range.upperBound)
            guard lower < upper else { return nil }
            return (lower - range.lowerBound)..<(upper - range.lowerBound)
        }
    }
}
