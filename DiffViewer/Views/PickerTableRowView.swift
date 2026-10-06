import AppKit

/// A table row whose highlight is a neutral fill, inset from the popover's sides with
/// rounded corners. It never paints a background of its own, and has no hover fill:
/// hover moves the highlight.
final class PickerTableRowView: NSTableRowView {
    /// The highlight's look. The defaults are the commit picker's.
    @MainActor
    struct Style {
        var highlightColor = PickerMetrics.highlightColor
        var inset = PickerMetrics.rowInset
        var radius = PickerMetrics.cornerRadius
        /// Outlines the highlight with the separator colour while Increase Contrast is on.
        var drawsContrastBorder = false
    }

    static let identifier = NSUserInterfaceItemIdentifier("PickerTableRowView")

    private let style: Style

    init(style: Style = Style()) {
        self.style = style
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
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: style.inset, dy: 0), xRadius: style.radius, yRadius: style.radius)
        style.highlightColor.setFill()
        path.fill()
        if style.drawsContrastBorder, NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            BranchPickerStyle.strokeRim(of: path, color: .separatorColor)
        }
    }
}
