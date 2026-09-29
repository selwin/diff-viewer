import AppKit

/// A table row whose highlight is the accent fill, inset from the popover's sides with
/// rounded corners, which the cell answers with white text. It never paints a background
/// of its own, and has no hover fill: hover moves the highlight.
final class PickerTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("PickerTableRowView")

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: PickerMetrics.rowInset, dy: 0), xRadius: PickerMetrics.cornerRadius,
            yRadius: PickerMetrics.cornerRadius
        ).fill()
    }
}
