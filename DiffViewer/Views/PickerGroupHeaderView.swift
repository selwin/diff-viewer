import AppKit

/// A section's title, such as a recency group. Never selectable: the table's handler
/// says it takes no highlight.
final class PickerGroupHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PickerGroupHeaderView")

    private let title = PickerLabel.make(
        font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
        addSubview(title)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(title text: String) {
        title.stringValue = text
        setAccessibilityLabel(text)
        needsLayout = true
    }

    /// Sits low in its row, close to the rows it names.
    override func layout() {
        super.layout()
        let leading = PickerMetrics.rowInset + PickerMetrics.contentInset
        let height = PickerViewGeometry.naturalSize(of: title).height
        title.frame = NSRect(
            x: leading, y: bounds.height - height - 4, width: max(bounds.width - leading * 2, 0), height: height)
    }
}
