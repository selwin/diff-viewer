import AppKit

/// A search field without a bezel, drawn over a `RoundedFillView`.
final class FilledSearchField: NSSearchField {
    override static var cellClass: AnyClass? {
        get { FilledSearchFieldCell.self }
        set {}
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Without a bezel the cell no longer keeps its text clear of the magnifier and the clear
/// button, so it is told where each goes, and the drawn text and the field editor are
/// both put in the text's place.
final class FilledSearchFieldCell: NSSearchFieldCell {
    private static let buttonWidth: CGFloat = 22

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        searchTextRect(forBounds: rect)
    }

    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate,
            start: selStart, length: selLength)
    }

    override func edit(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?
    ) {
        super.edit(
            withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate,
            event: event)
    }

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: rect.minY, width: Self.buttonWidth, height: rect.height)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let inset = Self.buttonWidth + 2
        return NSRect(x: rect.minX + inset, y: rect.minY, width: max(rect.width - inset * 2, 0), height: rect.height)
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - Self.buttonWidth, y: rect.minY, width: Self.buttonWidth, height: rect.height)
    }
}

/// A quiet capsule fill, behind a borderless control.
final class RoundedFillView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Tuned to read as #F1F1F2 on the light popover; labelColor keeps dark mode in step.
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}
