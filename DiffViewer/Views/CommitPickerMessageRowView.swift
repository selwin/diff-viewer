import AppKit

/// The row that ends the commit list: a spinner while loading, the message, and a link
/// for Retry or Search older commits. A message with a link is a row like any other: it
/// takes the highlight, and a click or a press runs its action.
final class CommitPickerMessageRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CommitPickerMessageRowView")
    static let height: CGFloat = 36

    private static let linkFont = NSFont.systemFont(ofSize: PickerStyle.metaFont.pointSize, weight: .semibold)
    private static let spinnerSize: CGFloat = 16
    private static let gap: CGFloat = 6

    /// Set by the table's owner; nil for a message without an action.
    var onActivate: (() -> Void)?

    private let spinner = NSProgressIndicator()
    private let label = PickerLabel.make(font: PickerStyle.metaFont, color: PickerStyle.meta)
    private let link = PickerLabel.make(font: linkFont, color: PickerStyle.accent)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [spinner, label, link] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(_ message: CommitPickerMessage) {
        label.stringValue = message.text
        link.stringValue = message.linkTitle ?? ""
        link.isHidden = message.linkTitle == nil
        if message.showsSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !message.showsSpinner
        setAccessibilityLabel([message.text, message.linkTitle].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    /// Spinner, message and link on one line from the shared edge; the message truncates
    /// before the link does.
    override func layout() {
        super.layout()
        var x = PickerStyle.edgeInset
        let maxX = bounds.width - x
        if !spinner.isHidden {
            let side = Self.spinnerSize
            spinner.frame = NSRect(x: x, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
            x = spinner.frame.maxX + Self.gap
        }
        let linkSize = link.isHidden ? .zero : PickerViewGeometry.naturalSize(of: link)
        let linkRoom = link.isHidden ? 0 : linkSize.width + Self.gap
        let labelSize = PickerViewGeometry.naturalSize(of: label)
        label.frame = NSRect(
            x: x, y: ((bounds.height - labelSize.height) / 2).rounded(),
            width: max(min(labelSize.width, maxX - x - linkRoom), 0), height: labelSize.height)
        guard !link.isHidden else { return }
        link.frame = NSRect(
            x: label.frame.maxX + Self.gap, y: ((bounds.height - linkSize.height) / 2).rounded(),
            width: linkSize.width, height: linkSize.height)
    }
}
