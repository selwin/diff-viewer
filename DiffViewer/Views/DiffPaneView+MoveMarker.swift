import AppKit

/// The chevron beside the first line of a moved run: where it sits, how it is drawn, and
/// which row a click on it jumps to. Placed from `rowRect.minX` like the gutter, so it
/// stays put and clickable while the pane scrolls horizontally.
extension DiffPaneView {
    /// The move marker's clickable area: the gutter's right margin, between the line
    /// number (right-aligned 10 pt from the gutter's edge) and the divider.
    func markerRect(forRowRect rowRect: NSRect) -> NSRect {
        NSRect(x: rowRect.minX + gutterWidth - 10, y: rowRect.minY, width: 9, height: rowRect.height)
    }

    /// A chevron toward the move's other end, when `line` starts a moved run.
    func drawMoveMarker(forLine line: Int, rowRect: NSRect, model: PaneModel, context: CGContext) {
        guard let marker = model.moveMarker(forLine: line) else { return }
        let rect = markerRect(forRowRect: rowRect)
        let pointingUp = marker.pointsUp
        context.saveGState()
        context.setStrokeColor(DiffTheme.movedAccent.cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let halfWidth: CGFloat = 3
        let height: CGFloat = 3
        // The view is flipped: smaller y is higher on screen.
        let apexY = pointingUp ? rect.midY - height / 2 : rect.midY + height / 2
        let baseY = pointingUp ? rect.midY + height / 2 : rect.midY - height / 2
        context.move(to: CGPoint(x: rect.midX - halfWidth, y: baseY))
        context.addLine(to: CGPoint(x: rect.midX, y: apexY))
        context.addLine(to: CGPoint(x: rect.midX + halfWidth, y: baseY))
        context.strokePath()
        context.restoreGState()
    }

    /// The document row a move marker under `point` jumps to: the other side's first row
    /// of the move.
    func moveMarkerTarget(at point: NSPoint) -> Int? {
        guard onJumpToDocumentRow != nil, let model, point.y >= 0, point.y < layout.contentHeight else { return nil }
        let index = layout.row(atY: point.y)
        guard index < displayRows.count, case let .documentRow(row) = displayRows[index],
            model.rows.indices.contains(row), let cell = model.cell(model.rows[row]),
            let marker = model.moveMarker(forLine: cell.lineIndex),
            markerRect(forRowRect: rowRect(at: index)).contains(point)
        else { return nil }
        return marker.partnerRow
    }

    /// One button per visible marker; the pointer is otherwise the only way to jump.
    func moveMarkerElements() -> [NSAccessibilityElement] {
        guard let onJumpToDocumentRow, let model else { return [] }
        let label = model.side == .old ? "Go to where these lines moved" : "Go to where these lines came from"
        var elements: [NSAccessibilityElement] = []
        for index in layout.rows(intersecting: visibleRect.minY, visibleRect.maxY) where index < displayRows.count {
            guard case let .documentRow(row) = displayRows[index], let cell = model.cell(model.rows[row]),
                let marker = model.moveMarker(forLine: cell.lineIndex)
            else { continue }
            elements.append(
                ButtonElement(
                    parent: self, frame: markerRect(forRowRect: rowRect(at: index)), label: label,
                    onPress: { onJumpToDocumentRow(marker.partnerRow) }))
        }
        return elements
    }
}
