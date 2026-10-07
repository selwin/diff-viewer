import AppKit

/// A table row whose highlight is a raised control, inset from the popover's sides with
/// rounded corners: a flat white fill alone barely shows on the light glass. It never paints a background of its own, and has no hover fill:
/// hover moves the highlight.
final class PickerTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("PickerTableRowView")
    /// Keeps the raised shadow inside the row, which clips.
    private static let verticalInset: CGFloat = 2

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {}

    /// Drawn rather than layered, so a dynamic colour follows appearance changes.
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let radius = PickerStyle.highlightRadius
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: PickerStyle.highlightInset, dy: Self.verticalInset), xRadius: radius,
            yRadius: radius)
        // Its rim turns to the separator colour with Increase Contrast.
        PickerStyle.drawRaised(path, fill: PickerStyle.raisedFill(.highlight))
    }
}
