import AppKit

/// A section's title, such as a recency group. Never selectable: the table's handler
/// says it takes no highlight.
final class PickerGroupHeaderView: NSTableCellView {
    /// The title's font, colour and place. The defaults are the commit picker's.
    @MainActor
    struct Style {
        var font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        var color = NSColor.secondaryLabelColor
        var leading = PickerMetrics.rowInset + PickerMetrics.contentInset
        /// Between the title and the bottom of its row, so it sits close to the rows it names.
        var bottomPadding: CGFloat = 4
    }

    static let identifier = NSUserInterfaceItemIdentifier("PickerGroupHeaderView")

    private let style: Style
    private let title: NSTextField

    init(style: Style = Style()) {
        self.style = style
        title = PickerLabel.make(font: style.font, color: style.color)
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
        title.frame = NSRect(
            x: style.leading, y: bounds.height - height - style.bottomPadding,
            width: max(bounds.width - style.leading * 2, 0), height: height)
    }
}
