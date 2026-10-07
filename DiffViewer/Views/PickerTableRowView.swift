import AppKit

/// A table row whose highlight is a rounded fill, inset from the popover's sides. It never paints a background of its own, and has no hover fill:
/// hover moves the highlight.
final class PickerTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("PickerTableRowView")

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
            roundedRect: bounds.insetBy(dx: PickerStyle.highlightInset, dy: 0), xRadius: radius, yRadius: radius)
        PickerStyle.rowHighlight.setFill()
        path.fill()
        // Increase Contrast outlines the highlight, which its translucent fill doesn't set apart.
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            PickerStyle.strokeRim(of: path, color: .separatorColor)
        }
    }
}
