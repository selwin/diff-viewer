import AppKit
import CoreText

/// Mouse and menu input for a pane: fold separator clicks, the cursor, text selection
/// by drag, double click (word) or triple click (line), and the Edit menu's Copy and
/// Select All.
extension DiffPaneView {

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// Pointing hand on a separator, I-beam over text, arrow over the gutter and pads.
    private func cursor(at point: NSPoint) -> NSCursor {
        if separatorHidden(at: point) != nil { return .pointingHand }
        guard let model, !displayRows.isEmpty, point.x >= visibleRect.minX + gutterWidth else { return .arrow }
        let index = layout.row(atY: point.y)
        guard index < displayRows.count, case let .documentRow(row) = displayRows[index],
            model.rows.indices.contains(row), model.cell(model.rows[row]) != nil
        else { return .arrow }
        return .iBeam
    }

    // MARK: - Separators

    /// The hidden range of the separator row under `point`, if any.
    func separatorHidden(at point: NSPoint) -> (index: Int, hidden: Range<Int>)? {
        guard onFoldAction != nil, point.y >= 0, point.y < layout.contentHeight else { return nil }
        let index = layout.row(atY: point.y)
        guard index < displayRows.count, case let .separator(hidden) = displayRows[index] else { return nil }
        return (index, hidden)
    }

    func separatorRowRect(at index: Int) -> NSRect {
        NSRect(x: visibleRect.minX, y: layout.y(forRow: index), width: visibleRect.width, height: layout.rowHeight)
    }

    static func action(for control: FoldControl, hidden: Range<Int>) -> FoldAction {
        switch control {
        case .expandUp: .expandUp(hidden)
        case .expandDown: .expandDown(hidden)
        case .expandRun: .expandRun(hidden)
        }
    }

    // MARK: - Hit testing

    /// The document row and raw UTF-16 offset under `point`. Nil when there is no
    /// document or the point is on a separator row; offset 0 over a pad or the gutter.
    func textPosition(at point: NSPoint) -> TextPosition? {
        guard let model, !displayRows.isEmpty else { return nil }
        let index = layout.row(atY: point.y)
        guard index < displayRows.count, case let .documentRow(row) = displayRows[index],
            model.rows.indices.contains(row)
        else { return nil }
        guard let cell = model.cell(model.rows[row]), point.x >= visibleRect.minX + gutterWidth else {
            return TextPosition(row: row, offset: 0)
        }
        let cached = cachedLine(for: cell.lineIndex, model: model)
        let position = CGPoint(x: point.x - (gutterWidth + textInset), y: 0)
        var expanded = CTLineGetStringIndexForPosition(cached.line, position)
        if expanded == kCFNotFound { expanded = 0 }
        let raw = cached.map.map { TabExpander.rawIndex(forExpanded: expanded, map: $0) } ?? expanded
        return TextPosition(row: row, offset: min(max(raw, 0), cached.rawLength))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let onFoldAction, let (index, hidden) = separatorHidden(at: point) {
            if event.modifierFlags.contains(.option) { return onFoldAction(.expandAll) }
            let control = controlRects(for: hidden, rowRect: separatorRowRect(at: index)).first(where: {
                $0.rect.contains(point)
            })?.control
            return onFoldAction(Self.action(for: control ?? .expandRun, hidden: hidden))
        }
        guard let position = textPosition(at: point) else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        onInteraction?()
        if event.clickCount >= 3 {
            selection = PaneSelection(
                anchor: TextPosition(row: position.row, offset: 0),
                head: TextPosition(row: position.row, offset: model?.lineLength(ofRow: position.row) ?? 0))
        } else if event.clickCount == 2, let word = wordRange(at: position) {
            selection = PaneSelection(
                anchor: TextPosition(row: position.row, offset: word.lowerBound),
                head: TextPosition(row: position.row, offset: word.upperBound))
        } else {
            selection = PaneSelection(anchor: position, head: position)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        if let position = textPosition(at: convert(event.locationInWindow, from: nil)) {
            selection?.head = position
        }
    }

    override func mouseUp(with event: NSEvent) {
        if selection?.isEmpty == true { selection = nil }
    }

    private func wordRange(at position: TextPosition) -> Range<Int>? {
        guard let model, model.rows.indices.contains(position.row),
            let cell = model.cell(model.rows[position.row])
        else { return nil }
        return WordSelection.range(in: model.lines[cell.lineIndex], at: position.offset)
    }

    // MARK: - Edit menu

    @objc func copy(_ sender: Any?) {
        guard let model, let selection else { return }
        let text = model.text(in: selection)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard let model else { return }
        onInteraction?()
        selection = model.fullSelection
    }
}

extension DiffPaneView: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selection != nil }
        if item.action == #selector(selectAll(_:)) { return !(model?.rows.isEmpty ?? true) }
        return true
    }
}
