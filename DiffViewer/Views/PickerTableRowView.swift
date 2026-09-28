import AppKit

/// A table row that highlights only its content area, with rounded corners, and
/// never paints a background of its own so the gutter shows through. In the commit
/// picker the highlight is a neutral fill, so the text keeps its colors; in the branch
/// picker it is the accent fill, which the cell answers with white text.
final class PickerTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("PickerTableRowView")

    enum Style {
        /// Neutral fills inside the content area, beside the gutter.
        case commitPicker
        /// An accent fill across the row, and no hover fill: hover moves the highlight.
        case branchPicker
    }

    var style = Style.commitPicker {
        didSet { if style != oldValue { needsDisplay = true } }
    }

    /// Set by the table's pointer tracking; drawn only while the row is not selected.
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var highlightPath: NSBezierPath {
        let rect =
            switch style {
            case .commitPicker: CommitPickerMetrics.contentRect(in: bounds)
            case .branchPicker: bounds.insetBy(dx: PickerMetrics.rowInset, dy: 0)
            }
        return NSBezierPath(
            roundedRect: rect, xRadius: PickerMetrics.cornerRadius, yRadius: PickerMetrics.cornerRadius)
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        guard style == .commitPicker, isHovered, !isSelected else { return }
        CommitPickerMetrics.hoverColor.setFill()
        highlightPath.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        switch style {
        case .commitPicker: CommitPickerMetrics.highlightColor.setFill()
        case .branchPicker: NSColor.selectedContentBackgroundColor.setFill()
        }
        highlightPath.fill()
    }
}
