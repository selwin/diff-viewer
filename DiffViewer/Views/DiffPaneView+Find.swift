import AppKit

/// Find hits: their fills, and the geometry the container needs to reveal one.
extension DiffPaneView {
    /// The x span of `range` in document `row` on this side, in pane coordinates. Nil when
    /// the row has no cell here.
    func horizontalBounds(ofRow row: Int, range: Range<Int>) -> (x0: CGFloat, x1: CGFloat)? {
        guard let model, let cell = model.cell(atRow: row) else { return nil }
        let cached = cachedLine(for: cell.lineIndex, model: model)
        let clamped = min(range.lowerBound, cached.rawLength)..<min(range.upperBound, cached.rawLength)
        let (x0, x1) = horizontalBounds(clamped, in: cached)
        return (documentTextX + x0, documentTextX + x1)
    }

    /// Over the token highlights and under the selection. A match that is exactly the
    /// selection is the current one and gets its own colour; `drawSelection` skips it.
    func drawFindMatches(ofRow row: Int, cached: CachedLine, in rowRect: NSRect, context: CGContext) {
        guard let ranges = findMatches[row] else { return }
        let current = selectedFindMatch(inRow: row)
        for range in ranges {
            let (x0, x1) = horizontalBounds(range, in: cached)
            guard x1 > x0 else { continue }
            (range == current ? DiffTheme.findCurrentMatch : DiffTheme.findMatch).setFill()
            let rect = textSpanRect(x0: x0, x1: x1, in: rowRect)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.fillPath()
        }
    }

    /// The selection's range in `row` when it covers exactly one find match there.
    func selectedFindMatch(inRow row: Int) -> Range<Int>? {
        guard let selection, selection.start.row == row, let range = selection.singleRowRange else { return nil }
        return findMatches[row]?.contains(range) == true ? range : nil
    }
}
