import AppKit

/// What the picker's table asks of its owner on a plain key press or a click.
@MainActor
protocol PickerTableHandler: AnyObject {
    func moveUp()
    func moveDown()
    func moveToFirst()
    func moveToLast()
    func activate()
    func activate(tableRow: Int)
    func cancel()
}

/// The picker's table: unmodified navigation keys go to the handler, everything else
/// (type-select included) to AppKit. A click on a row activates it on release, so a
/// drag off the row cancels; clicks in the gutter, which belongs to the day labels, and
/// below the rows are swallowed, and so are clicks on a row's accessory, whose buttons
/// take their own. Tracks the hovered row.
final class CommitPickerTableView: NSTableView {
    weak var handler: (any PickerTableHandler)?
    /// Called with the previously hovered row and the new one whenever the hover moves.
    var onHoverChange: ((_ previous: Int?, _ current: Int?) -> Void)?

    private var trackingArea: NSTrackingArea?
    private(set) var hoveredRow: Int?
    /// The row the mouse went down on, until it comes up.
    private var pressedRow: Int?

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.isDisjoint(with: modifiers), let handler else {
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 126: handler.moveUp()
        case 125: handler.moveDown()
        case 115: handler.moveToFirst()
        case 119: handler.moveToLast()
        case 36, 76: handler.activate()
        case 53: handler.cancel()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Mouse

    // Never `super`, so AppKit does not move the selection under the activation.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A disabled button, or the gap between two, passes the press up to here.
        pressedRow = isOnAccessory(point) ? nil : contentRow(at: point)
    }

    /// Drops a press in flight: after a reload the same index can name another row.
    func cancelPress() {
        pressedRow = nil
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedRow = nil }
        let point = convert(event.locationInWindow, from: nil)
        // A release over the row's buttons cancels, as it would over any other control.
        guard let pressedRow, !isOnAccessory(point), contentRow(at: point) == pressedRow else { return }
        handler?.activate(tableRow: pressedRow)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHoveredRow(contentRow(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseMoved(with event: NSEvent) {
        setHoveredRow(contentRow(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredRow(nil)
    }

    /// Re-reads the pointer after the rows moved under it: a scroll or a reload.
    func refreshHover() {
        guard let window, window.isKeyWindow else { return setHoveredRow(nil) }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(visibleRect.contains(point) ? contentRow(at: point) : nil)
    }

    private func isOnAccessory(_ point: NSPoint) -> Bool {
        let row = row(at: point)
        guard row >= 0,
            let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? ScopeRowContentView,
            let accessory = cell.accessory, !accessory.isHidden
        else { return false }
        return accessory.bounds.contains(accessory.convert(point, from: self))
    }

    /// The row under `point`, or nil in the gutter or below the rows.
    private func contentRow(at point: NSPoint) -> Int? {
        guard point.x >= CommitPickerMetrics.gutterWidth else { return nil }
        let row = row(at: point)
        return row >= 0 ? row : nil
    }

    private func setHoveredRow(_ row: Int?) {
        guard row != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = row
        // The previous row can be past the end after a reload shrank the table.
        for index in [previous, row].compactMap({ $0 }) where index < numberOfRows {
            (rowView(atRow: index, makeIfNecessary: false) as? CommitPickerTableRowView)?.isHovered = index == row
        }
        onHoverChange?(previous, row)
    }
}
