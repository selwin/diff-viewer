import AppKit

/// Find hits: their fills, and the geometry the container needs to reveal one.
extension DiffPaneView {
    /// The x span of `range` in document `row` on this side, in pane coordinates. Nil when
    /// the row has no cell here.
    func horizontalBounds(ofRow row: Int, range: Range<Int>) -> (x0: CGFloat, x1: CGFloat)? {
        guard let model, model.rows.indices.contains(row), let cell = model.cell(model.rows[row]) else { return nil }
        let cached = cachedLine(for: cell.lineIndex, model: model)
        let clamped = min(range.lowerBound, cached.rawLength)..<min(range.upperBound, cached.rawLength)
        let (x0, x1) = horizontalBounds(clamped, in: cached)
        let origin = gutterWidth + textInset
        return (origin + x0, origin + x1)
    }

    /// Over the token highlights and under the selection, so the current match (which is
    /// selected) reads differently from the others.
    func drawFindMatches(ofRow row: Int, cached: CachedLine, in rowRect: NSRect, context: CGContext) {
        guard let ranges = findMatches[row] else { return }
        DiffTheme.findMatch.setFill()
        for range in ranges {
            let (x0, x1) = horizontalBounds(range, in: cached)
            guard x1 > x0 else { continue }
            context.fill(
                NSRect(
                    x: gutterWidth + textInset + x0, y: rowRect.minY + 1, width: x1 - x0, height: rowRect.height - 2))
        }
    }
}
