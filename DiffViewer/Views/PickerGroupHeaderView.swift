import AppKit

/// A section's title, such as a recency group. Never selectable: the table's handler
/// says it takes no highlight.
final class PickerGroupHeaderView: NSTableCellView {
    /// Between the title and the bottom of its row, so it sits close to the rows it names.
    private static let bottomPadding: CGFloat = 6

    static let identifier = NSUserInterfaceItemIdentifier("PickerGroupHeaderView")

    private let title: NSTextField

    init() {
        title = PickerLabel.make(font: PickerStyle.sectionFont, color: PickerStyle.section)
        super.init(frame: .zero)
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

    override func layout() {
        super.layout()
        let height = PickerViewGeometry.naturalSize(of: title).height
        let leading = PickerStyle.edgeInset
        title.frame = NSRect(
            x: leading, y: bounds.height - height - Self.bottomPadding,
            width: max(bounds.width - leading * 2, 0), height: height)
    }
}
