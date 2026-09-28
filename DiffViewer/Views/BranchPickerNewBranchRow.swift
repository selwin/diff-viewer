import AppKit

/// The branch picker's New Branch… row, under the list: a plus, the title, and ⌘N on the
/// right as a menu shows a shortcut. Outside the table, so the list's highlight and arrow
/// keys never reach it; the pointer gives it its own hover fill.
final class BranchPickerNewBranchRow: NSView {
    static let height: CGFloat = 32

    private static let iconSize: CGFloat = 14
    private static let iconGap: CGFloat = 9

    var onActivate: () -> Void = {}

    /// Off while a switch runs: the branch would start from a HEAD about to move.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            applyColors()
            needsDisplay = true
        }
    }

    private let icon = NSImageView()
    private let title = CommitPickerMetrics.label(font: .systemFont(ofSize: 13), color: .labelColor)
    private let shortcut = CommitPickerMetrics.label(
        font: .systemFont(ofSize: 13), color: .tertiaryLabelColor, alignment: .right)
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.stringValue = "New Branch…"
        shortcut.stringValue = "⌘N"
        for view in [icon, title, shortcut] { addSubview(view) }
        // `.activeAlways`: a scripted launch never makes the popover key.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("New Branch")
        setAccessibilityHelp("Create a branch from HEAD and switch to it (⌘N)")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The first click in an inactive popover acts, as a row's does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The labels are decoration: clicks on them belong to the row.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// Acts on release inside, like a button: a press dragged off cancels.
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let wasPressed = isPressed
        isPressed = false
        if isEnabled, wasPressed, inside { onActivate() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onActivate()
        return true
    }

    override func isAccessibilityEnabled() -> Bool { isEnabled }

    private func applyColors() {
        icon.contentTintColor = isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        title.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
        shortcut.textColor = isEnabled ? .tertiaryLabelColor : .quaternaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isEnabled, isHovered || isPressed else { return }
        let fill = isPressed ? CommitPickerMetrics.highlightColor : CommitPickerMetrics.hoverColor
        fill.setFill()
        let rect = bounds.insetBy(dx: BranchPickerMetrics.rowInset, dy: 0)
        NSBezierPath(
            roundedRect: rect, xRadius: CommitPickerMetrics.cornerRadius, yRadius: CommitPickerMetrics.cornerRadius
        ).fill()
    }

    /// Lined up with the rows above: the icon over theirs, the text over their names.
    override func layout() {
        super.layout()
        let leading = BranchPickerMetrics.rowInset + BranchPickerMetrics.contentInset
        let trailing = bounds.width - leading
        icon.frame = NSRect(
            x: leading, y: ((bounds.height - Self.iconSize) / 2).rounded(), width: Self.iconSize,
            height: Self.iconSize)
        let shortcutSize = CommitPickerMetrics.naturalSize(of: shortcut)
        shortcut.frame = NSRect(
            x: trailing - shortcutSize.width, y: ((bounds.height - shortcutSize.height) / 2).rounded(),
            width: shortcutSize.width, height: shortcutSize.height)
        let textX = icon.frame.maxX + Self.iconGap
        let titleHeight = CommitPickerMetrics.naturalSize(of: title).height
        title.frame = NSRect(
            x: textX, y: ((bounds.height - titleHeight) / 2).rounded(),
            width: max(shortcut.frame.minX - 8 - textX, 0), height: titleHeight)
    }
}
