import AppKit

/// The branch picker's New Branch… button: a Liquid Glass capsule floating over the
/// list's last rows, with a plus and the title centred in the accent colour and a faint
/// ⌘N at its trailing end. Only the capsule takes the pointer; the margin around it passes
/// clicks on to the list. Outside the table, so the list's own selection never reaches
/// it; it is styled from the picker's highlight state.
final class BranchPickerNewBranchRow: NSView {
    /// Room around the capsule so the clip doesn't cut the glass's shadow.
    static let glassMargin: CGFloat = 8
    private static let iconGap: CGFloat = 6
    /// Between the capsule's ends and its content: the hint sits here, and the title
    /// truncates before reaching the hint's mirror on the leading side.
    private static let padding: CGFloat = 16
    private static let hintGap: CGFloat = 8
    /// The size and weight of the sync buttons' shortcut glyphs.
    private static let hintFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    var onActivate: () -> Void = {}
    /// The pointer entered, moved over, or pressed the capsule: it asks to take the highlight.
    var onHighlightRequested: () -> Void = {}
    /// A scroll over the capsule, which belongs to the list beneath it.
    var onScroll: (NSEvent) -> Void = { _ in }

    /// Set by the container from the picker state; tints the glass.
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { applyTint() } }
    }

    /// Off while a switch runs: the branch would start from a HEAD about to move.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            applyColors()
            applyTint()
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

    private let glass = NSGlassEffectView()
    private let icon = NSImageView()
    private let title = PickerLabel.make(font: PickerStyle.footerFont, color: PickerStyle.accent)
    private let hint = PickerLabel.make(font: hintFont, color: PickerStyle.placeholder)
    private var isPressed = false {
        didSet { if isPressed != oldValue { applyTint() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.imageScaling = .scaleNone
        hint.stringValue = "⌘N"
        // The help already names the shortcut.
        hint.setAccessibilityElement(false)
        let content = NSView()
        for view in [icon, title, hint] { content.addSubview(view) }
        glass.contentView = content
        addSubview(glass)
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
        bounds.insetBy(dx: Self.glassMargin, dy: Self.glassMargin)
    }

    /// Whether the pointer is over the capsule, which hides the rows beneath it.
    var isUnderPointer: Bool {
        guard let window else { return false }
        return capsuleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// The first click in an inactive popover acts, as a row's does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The glass and labels are decoration: clicks on them belong to the capsule, and the
    /// margin passes them on to the list.
    override func hitTest(_ point: NSPoint) -> NSView? {
        capsuleRect.contains(convert(point, from: superview)) ? self : nil
    }

    /// The tracking area covers the margin too, which isn't the button.
    override func mouseEntered(with event: NSEvent) { requestHighlight(for: event) }
    /// A real pointer move takes the highlight back from the keyboard, as in the list.
    override func mouseMoved(with event: NSEvent) { requestHighlight(for: event) }

    private func requestHighlight(for event: NSEvent) {
        if capsuleRect.contains(convert(event.locationInWindow, from: nil)) { onHighlightRequested() }
    }

    override func scrollWheel(with event: NSEvent) { onScroll(event) }

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
        let color = isEnabled ? PickerStyle.accent : .tertiaryLabelColor
        icon.contentTintColor = color
        title.textColor = color
        // Tertiary is unreadable on glass over rows; the placeholder grey is a step stronger.
        hint.textColor = isEnabled ? PickerStyle.placeholder : .tertiaryLabelColor
    }

    /// Clear at rest; tinted with the row highlight's white when highlighted, and the
    /// raised press's greyer white while pressed, so it lifts like a highlighted row.
    private func applyTint() {
        glass.tintColor = !isEnabled ? nil : isPressed ? Self.pressedTint : isHighlighted ? Self.highlightTint : nil
    }

    /// Lighter than a row's highlight: the glass already reads as a raised surface.
    private static let highlightTint = tint(light: NSColor(white: 1, alpha: 0.4), dark: NSColor(white: 1, alpha: 0.08))
    private static let pressedTint = tint(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.14))

    private static func tint(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    /// The glass adapts to the display options on its own; the tint is re-applied with them.
    func refreshRendering() {
        applyTint()
    }

    /// The plus and the title, centred together on the capsule clear of the hint on either
    /// side; a long proposal truncates.
    override func layout() {
        super.layout()
        let rect = capsuleRect
        glass.frame = rect
        glass.cornerRadius = rect.height / 2
        // The content view fills the glass; its labels are placed in the glass's bounds.
        let size = rect.size
        let hintSize = PickerViewGeometry.naturalSize(of: hint)
        hint.frame = NSRect(
            x: size.width - Self.padding - hintSize.width, y: ((size.height - hintSize.height) / 2).rounded(),
            width: hintSize.width, height: hintSize.height)
        let iconSize = icon.image?.size ?? .zero
        let titleSize = PickerViewGeometry.naturalSize(of: title)
        let sideRoom = Self.padding + hintSize.width + Self.hintGap
        let maxTitleWidth = max(size.width - sideRoom * 2 - iconSize.width - Self.iconGap, 0)
        let titleWidth = min(titleSize.width, maxTitleWidth)
        let x = (size.width / 2 - (iconSize.width + Self.iconGap + titleWidth) / 2).rounded()
        icon.frame = NSRect(
            x: x, y: ((size.height - iconSize.height) / 2).rounded(), width: iconSize.width, height: iconSize.height)
        title.frame = NSRect(
            x: icon.frame.maxX + Self.iconGap, y: ((size.height - titleSize.height) / 2).rounded(), width: titleWidth,
            height: titleSize.height)
    }
}
