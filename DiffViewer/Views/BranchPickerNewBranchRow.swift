import AppKit

/// The branch picker's New Branch… footer: a raised capsule with a plus and the title
/// centred in the accent colour. Its frame keeps `BranchPickerStyle.shadowMargin` around
/// the capsule for the shadow, and only the capsule takes the pointer. Outside the table,
/// so the list's own selection never reaches it; it is styled from the picker's highlight
/// state.
final class BranchPickerNewBranchRow: NSView {
    private static let iconGap: CGFloat = 6

    var onActivate: () -> Void = {}
    /// The pointer entered, moved over, or pressed the row: it asks to take the highlight.
    var onHighlightRequested: () -> Void = {}

    /// Set by the container from the picker state; drawn with the hover fill.
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    /// Off while a switch runs: the branch would start from a HEAD about to move.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            applyColors()
            needsDisplay = true
        }
    }

    /// The name the search proposes, which the title offers to create; nil for plain New
    /// Branch….
    var proposal: String? {
        didSet {
            guard proposal != oldValue else { return }
            applyTitle()
        }
    }

    private let icon = NSImageView()
    private let title = PickerLabel.make(font: BranchPickerStyle.footerFont, color: BranchPickerStyle.accent)
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.imageScaling = .scaleNone
        for view in [icon, title] { addSubview(view) }
        // `.activeAlways`: a scripted launch never makes the popover key.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self,
                userInfo: nil))
        toolTip = "Create a branch from HEAD (⌘N)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        applyTitle()
        setAccessibilityHelp("Create a branch from HEAD and switch to it (⌘N)")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var capsuleRect: NSRect {
        bounds.insetBy(dx: BranchPickerStyle.shadowMargin, dy: BranchPickerStyle.shadowMargin)
    }

    /// The first click in an inactive popover acts, as a row's does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The labels are decoration: clicks on them belong to the capsule, and the shadow's
    /// margin passes them on to the list.
    override func hitTest(_ point: NSPoint) -> NSView? {
        capsuleRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { onHighlightRequested() }
    /// A real pointer move takes the highlight back from the keyboard, as in the list.
    override func mouseMoved(with event: NSEvent) { onHighlightRequested() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // Before the press shows, so two rows are never highlighted at once.
        onHighlightRequested()
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = capsuleRect.contains(convert(event.locationInWindow, from: nil))
    }

    /// Acts on release inside, like a button: a press dragged off cancels.
    override func mouseUp(with event: NSEvent) {
        let inside = capsuleRect.contains(convert(event.locationInWindow, from: nil))
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

    private func applyTitle() {
        guard let proposal else {
            title.stringValue = "New Branch…"
            setAccessibilityLabel("New Branch")
            needsLayout = true
            return
        }
        title.stringValue = "Create “\(proposal)”"
        setAccessibilityLabel("Create branch \(proposal)")
        needsLayout = true
    }

    private func applyColors() {
        let color = isEnabled ? BranchPickerStyle.accent : .tertiaryLabelColor
        icon.contentTintColor = color
        title.textColor = color
    }

    /// Redraws with the current accessibility display options.
    func refreshRendering() {
        needsDisplay = true
    }

    /// Raised at rest, lifted when highlighted, greyer while pressed.
    override func draw(_ dirtyRect: NSRect) {
        let state: BranchPickerStyle.Raised =
            !isEnabled ? .rest : isPressed ? .pressed : isHighlighted ? .hover : .rest
        let rect = capsuleRect
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        BranchPickerStyle.drawRaised(path, fill: BranchPickerStyle.raisedFill(state))
    }

    /// The plus and the title, centred together on the capsule; a long proposal truncates.
    override func layout() {
        super.layout()
        let rect = capsuleRect
        let iconSize = icon.image?.size ?? .zero
        let titleSize = PickerViewGeometry.naturalSize(of: title)
        let maxTitleWidth = max(rect.width - 32 - iconSize.width - Self.iconGap, 0)
        let titleWidth = min(titleSize.width, maxTitleWidth)
        let x = (rect.midX - (iconSize.width + Self.iconGap + titleWidth) / 2).rounded()
        icon.frame = NSRect(
            x: x, y: (rect.midY - iconSize.height / 2).rounded(), width: iconSize.width, height: iconSize.height)
        title.frame = NSRect(
            x: icon.frame.maxX + Self.iconGap, y: (rect.midY - titleSize.height / 2).rounded(), width: titleWidth,
            height: titleSize.height)
    }
}
