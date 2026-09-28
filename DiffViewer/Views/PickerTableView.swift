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
    /// False for rows that take no hover, highlight or click, such as section headers.
    func canHighlight(tableRow: Int) -> Bool
}

/// A row cell with controls of its own, whose clicks must not activate the row.
@MainActor
protocol PickerRowAccessoryHosting: AnyObject {
    var accessory: NSView? { get }
}

/// The picker's table: unmodified navigation keys go to the handler, everything else
/// (type-select included) to AppKit. A click activates its row on release, so a drag off
/// the row cancels. Clicks below the rows, on rows that take no highlight, or on a row's
/// accessory never activate one. Tracks the hovered row.
final class PickerTableView: NSTableView {
    weak var handler: (any PickerTableHandler)?
    /// Called with the previously hovered row and the new one whenever the hover moves.
    /// `pointerMoved` is false when the rows moved under a still pointer: a scroll or a
    /// reload, which a keyboard move can cause.
    var onHoverChange: ((_ previous: Int?, _ current: Int?, _ pointerMoved: Bool) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var hoveredRow: Int?
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
        setHoveredRow(contentRow(at: convert(event.locationInWindow, from: nil)), pointerMoved: true)
    }

    override func mouseMoved(with event: NSEvent) {
        setHoveredRow(contentRow(at: convert(event.locationInWindow, from: nil)), pointerMoved: true)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredRow(nil, pointerMoved: true)
    }

    /// Re-reads the pointer after the rows moved under it: a scroll or a reload.
    func refreshHover() {
        guard let window, window.isKeyWindow else { return setHoveredRow(nil, pointerMoved: false) }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(visibleRect.contains(point) ? contentRow(at: point) : nil, pointerMoved: false)
    }

    private func isOnAccessory(_ point: NSPoint) -> Bool {
        let row = row(at: point)
        guard row >= 0,
            let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? any PickerRowAccessoryHosting,
            let accessory = cell.accessory, !accessory.isHidden
        else { return false }
        // An accessory click must not activate its row, even while the accessory fades out
        // and refuses the click itself.
        return accessory.bounds.contains(accessory.convert(point, from: self))
    }

    /// The row under `point`, or nil on a row that takes no highlight or below the rows.
    private func contentRow(at point: NSPoint) -> Int? {
        let row = row(at: point)
        guard row >= 0, handler?.canHighlight(tableRow: row) ?? true else { return nil }
        return row
    }

    private func setHoveredRow(_ row: Int?, pointerMoved: Bool) {
        guard row != hoveredRow else {
            // The keyboard may have moved the highlight off this row since; a real move
            // lets the owner take it back. Nothing is redrawn here.
            if pointerMoved { onHoverChange?(row, row, true) }
            return
        }
        let previous = hoveredRow
        hoveredRow = row
        onHoverChange?(previous, row, pointerMoved)
    }
}
