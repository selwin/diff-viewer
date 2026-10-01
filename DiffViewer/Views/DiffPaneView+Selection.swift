import AppKit
import CoreText

/// Mouse and menu input for a pane: fold separator and scope copy clicks, the cursor, text selection
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
        refreshSeparatorHover()
    }

    override func mouseExited(with event: NSEvent) {
        clearSeparatorHover()
        NSCursor.arrow.set()
    }

    /// Allow the activation click to copy a scope name.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event, scopeCopyTarget(at: convert(event.locationInWindow, from: nil)) != nil { return true }
        return super.acceptsFirstMouse(for: event)
    }

    /// Pointing hand on a separator, a scope copy icon or a move marker, I-beam over text,
    /// arrow over the gutter and pads.
    private func cursor(at point: NSPoint, isOnScopeCopy: Bool) -> NSCursor {
        if isOnScopeCopy || separatorHidden(at: point) != nil || moveMarkerTarget(at: point) != nil {
            return .pointingHand
        }
        guard let model, !isOverGutter(point), let (_, row) = documentRow(at: point), model.cell(atRow: row) != nil
        else { return .arrow }
        return .iBeam
    }

    // MARK: - Hover

    /// Reads the pointer again: which separator shows the copy icon, and whether the icon
    /// is under it. Hover is only for drawing; clicks resolve the separator themselves.
    func refreshSeparatorHover() {
        // `.activeInKeyWindow`: the tracking area is silent elsewhere, so no hover there either.
        guard !isHiddenOrHasHiddenAncestor, let window, window.isKeyWindow else { return clearSeparatorHover() }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else { return clearSeparatorHover() }
        hoveredSeparatorRow = separatorRow(at: point)?.index
        let isOnScopeCopy = scopeCopyTarget(at: point) != nil
        isPointerOnScopeCopy = isOnScopeCopy
        // Only the pane under the pointer sets the cursor.
        cursor(at: point, isOnScopeCopy: isOnScopeCopy).set()
    }

    private func clearSeparatorHover() {
        hoveredSeparatorRow = nil
        isPointerOnScopeCopy = false
    }

    /// Coalesce hover updates until projection, sizing and scroll restoration finish; a
    /// still pointer sends no mouse event for them.
    func scheduleHoverRefresh() {
        guard !isHoverRefreshPending else { return }
        isHoverRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Cleared first, so a refresh that changes content can schedule another.
            isHoverRefreshPending = false
            refreshSeparatorHover()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleHoverRefresh()
    }

    override func viewDidHide() {
        super.viewDidHide()
        scheduleHoverRefresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        scheduleHoverRefresh()
    }

    // Only a window change needs removal; selector-based observers go away with the view.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard let window else { return }
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(
            self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowKeyChanged(_ note: Notification) {
        scheduleHoverRefresh()
    }

    // MARK: - Separators

    /// The separator row under `point`, whether or not folding is enabled.
    func separatorRow(at point: NSPoint) -> (index: Int, hidden: Range<Int>)? {
        guard point.y >= 0, point.y < layout.contentHeight else { return nil }
        let index = layout.row(atY: point.y)
        guard index < displayRows.count, case let .separator(hidden) = displayRows[index] else { return nil }
        return (index, hidden)
    }

    /// The hidden range of the separator row under `point`, when it can be folded.
    func separatorHidden(at point: NSPoint) -> (index: Int, hidden: Range<Int>)? {
        guard onFoldAction != nil else { return nil }
        return separatorRow(at: point)
    }

    /// The hidden range of the separator whose copy icon is under `point`.
    func scopeCopyTarget(at point: NSPoint) -> Range<Int>? {
        guard let (index, hidden) = separatorRow(at: point),
            let presentation = scopeLabelPresentation(
                for: hidden, layout: separatorLayout(for: hidden, rowRect: rowRect(at: index)).layout),
            presentation.copyRect.contains(point)
        else { return nil }
        return hidden
    }

    static func action(for control: FoldControl, hidden: Range<Int>) -> FoldAction {
        switch control {
        case .expandUp: .expandUp(hidden)
        case .expandDown: .expandDown(hidden)
        case .expandRun: .expandRun(hidden)
        }
    }

    // MARK: - Hit testing

    /// A display row at the visible left edge, where the gutter is drawn. Drawing and hit
    /// testing both start from it, so they agree while the pane scrolls horizontally.
    func rowRect(at displayIndex: Int) -> NSRect {
        NSRect(
            x: visibleRect.minX, y: layout.y(forRow: displayIndex), width: visibleRect.width,
            height: layout.rowHeight)
    }

    /// The display row under `y` and the document row it shows. `row(atY:)` clamps, so a
    /// drag past either end lands on the first or last row; a separator or header is nil.
    static func documentRow(
        atY y: CGFloat, layout: PaneLayout, displayRows: [DisplayRow], rowCount: Int
    ) -> (index: Int, row: Int)? {
        let index = layout.row(atY: y)
        guard index < displayRows.count, case let .documentRow(row) = displayRows[index], row >= 0, row < rowCount
        else { return nil }
        return (index, row)
    }

    func documentRow(at point: NSPoint) -> (index: Int, row: Int)? {
        guard let model else { return nil }
        return Self.documentRow(
            atY: point.y, layout: layout, displayRows: displayRows, rowCount: model.rows.count)
    }

    /// The gutter stays at the visible left edge during horizontal scrolling.
    func isOverGutter(_ point: NSPoint) -> Bool { point.x < visibleRect.minX + gutterWidth }

    /// The document row and raw UTF-16 offset under `point`. Nil when there is no
    /// document or the point is on a separator row; offset 0 over a pad or the gutter.
    func textPosition(at point: NSPoint) -> TextPosition? {
        guard let model, let (_, row) = documentRow(at: point) else { return nil }
        guard let cell = model.cell(atRow: row), !isOverGutter(point) else {
            return TextPosition(row: row, offset: 0)
        }
        let cached = cachedLine(for: cell.lineIndex, model: model)
        let position = CGPoint(x: point.x - documentTextX, y: 0)
        var expanded = CTLineGetStringIndexForPosition(cached.line, position)
        if expanded == kCFNotFound { expanded = 0 }
        let raw = cached.map.map { TabExpander.rawIndex(forExpanded: expanded, map: $0) } ?? expanded
        return TextPosition(row: row, offset: min(max(raw, 0), cached.rawLength))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        isSelectingText = false
        let point = convert(event.locationInWindow, from: nil)
        if let hidden = scopeCopyTarget(at: point) {
            return copyScopeName(hidden: hidden, generation: documentGeneration)
        }
        if let onFoldAction, let (index, hidden) = separatorHidden(at: point) {
            if event.modifierFlags.contains(.option) { return onFoldAction(.expandAll) }
            let control = separatorLayout(for: hidden, rowRect: rowRect(at: index)).layout.controls.first(where: {
                $0.rect.contains(point)
            })?.control
            return onFoldAction(Self.action(for: control ?? .expandRun, hidden: hidden))
        }
        if let onJumpToDocumentRow, let row = moveMarkerTarget(at: point) { return onJumpToDocumentRow(row) }
        guard let position = textPosition(at: point) else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        onInteraction?()
        isSelectingText = true
        if event.clickCount >= 3 {
            selection = PaneSelection(row: position.row, range: 0..<(model?.lineLength(ofRow: position.row) ?? 0))
        } else if event.clickCount == 2, let word = wordRange(at: position) {
            selection = PaneSelection(row: position.row, range: word)
        } else {
            selection = PaneSelection(anchor: position, head: position)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelectingText else { return }
        autoscroll(with: event)
        if let position = textPosition(at: convert(event.locationInWindow, from: nil)) {
            selection?.head = position
        }
    }

    override func mouseUp(with event: NSEvent) {
        isSelectingText = false
        if selection?.isEmpty == true { selection = nil }
    }

    private func wordRange(at position: TextPosition) -> Range<Int>? {
        guard let model, let cell = model.cell(atRow: position.row) else { return nil }
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
