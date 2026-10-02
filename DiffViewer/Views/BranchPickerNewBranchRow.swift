import AppKit

/// The branch picker's New Branch… row, under the list: a plus, the title, and ⌘N on the
/// right as a menu shows a shortcut. Outside the table, so the list's own selection never
/// reaches it; it is styled from the picker's highlight state.
final class BranchPickerNewBranchRow: NSView {
    static let height: CGFloat = 32

    private static let iconSize: CGFloat = 14
    private static let iconGap: CGFloat = 9

    var onActivate: () -> Void = {}
    /// The pointer entered, moved over, or pressed the row: it asks to take the highlight.
    var onHighlightRequested: () -> Void = {}

    /// Set by the container from the picker state; drawn as a highlighted branch row is.
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            applyColors()
            needsDisplay = true
        }
    }

    /// Off while a switch runs: the branch would start from a HEAD about to move.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            applyColors()
            needsDisplay = true
        }
    }

    private let icon = NSImageView()
    private let title = PickerLabel.make(font: .systemFont(ofSize: 13), color: .labelColor)
    private let shortcut = PickerLabel.make(
        font: .systemFont(ofSize: 13), color: .tertiaryLabelColor, alignment: .right)
    private var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            applyColors()
            needsDisplay = true
        }
    }
    /// Accent fill with white content, as the highlighted branch row has.
    private var isOnAccent: Bool { isEnabled && (isHighlighted || isPressed) }

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
                rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self,
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

    override func mouseEntered(with event: NSEvent) { onHighlightRequested() }
    /// A real pointer move takes the highlight back from the keyboard, as in the list.
    override func mouseMoved(with event: NSEvent) { onHighlightRequested() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // Before the press shows, so two rows are never on accent at once.
        onHighlightRequested()
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
        if isOnAccent {
            icon.contentTintColor = .white
            title.textColor = .white
            shortcut.textColor = NSColor.white.withAlphaComponent(0.8)
            return
        }
        icon.contentTintColor = isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        title.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
        shortcut.textColor = isEnabled ? .tertiaryLabelColor : .quaternaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isOnAccent else { return }
        NSColor.controlAccentColor.setFill()
        let rect = bounds.insetBy(dx: PickerMetrics.rowInset, dy: 0)
        NSBezierPath(
            roundedRect: rect, xRadius: PickerMetrics.cornerRadius, yRadius: PickerMetrics.cornerRadius
        ).fill()
    }

    /// Lined up with the rows above: the icon over theirs, the text over their names.
    override func layout() {
        super.layout()
        let leading = PickerMetrics.rowInset + PickerMetrics.contentInset
        let trailing = bounds.width - leading
        icon.frame = NSRect(
            x: leading, y: ((bounds.height - Self.iconSize) / 2).rounded(), width: Self.iconSize,
            height: Self.iconSize)
        let shortcutSize = PickerViewGeometry.naturalSize(of: shortcut)
        shortcut.frame = NSRect(
            x: trailing - shortcutSize.width, y: ((bounds.height - shortcutSize.height) / 2).rounded(),
            width: shortcutSize.width, height: shortcutSize.height)
        let textX = icon.frame.maxX + Self.iconGap
        let titleHeight = PickerViewGeometry.naturalSize(of: title).height
        title.frame = NSRect(
            x: textX, y: ((bounds.height - titleHeight) / 2).rounded(),
            width: max(shortcut.frame.minX - 8 - textX, 0), height: titleHeight)
    }
}
