import AppKit

/// A small borderless button that copies a string, such as a commit's SHA or a branch's
/// name, and shows a checkmark for a moment after it has. A rounded fill fades in behind
/// the icon while the pointer is over it.
final class PickerCopyButton: NSButton {
    /// The hover fill's side; the icon is 11pt, centred in it.
    static let side: CGFloat = 20

    private static let feedbackDuration: TimeInterval = 1.2
    private static let hoverDuration: TimeInterval = 0.15
    private static let copyImage = symbol("doc.on.doc")
    private static let copiedImage = symbol("checkmark")

    /// After the copy; the picker returns focus to its search field.
    var onCopy: () -> Void = {}

    /// White on the accent highlight, secondary elsewhere.
    var isOnAccent = false {
        didSet {
            guard isOnAccent != oldValue else { return }
            applyTint()
            applyFill()
        }
    }

    /// What a click copies.
    private(set) var text = ""
    /// Room around the icon for a focus ring, which the button's own bounds would clip.
    let focusMargin: CGFloat
    private var feedbackTimer: Timer?
    private var isHovered = false
    /// Subviews rather than the button's own image, so the fill can sit under the icon.
    private let fill = HoverFillView(frame: .zero)
    private let icon = NSImageView()

    /// `label` is the tooltip and the accessibility label. A non-zero `focusMargin` makes
    /// the button focusable, with its ring drawn in that margin.
    init(label: String, focusMargin: CGFloat = 0) {
        self.focusMargin = focusMargin
        super.init(frame: .zero)
        clipsToBounds = true
        isBordered = false
        title = ""
        icon.image = Self.copyImage
        icon.imageScaling = .scaleNone
        fill.wantsLayer = true
        fill.alphaValue = 0
        addSubview(fill)
        addSubview(icon)
        // `.activeAlways`: a scripted launch never makes the popover key.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                userInfo: nil))
        target = self
        action = #selector(copyText)
        toolTip = label
        setAccessibilityLabel(label)
        if focusMargin > 0 { focusRingType = .default }
        applyTint()
        applyFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    }

    /// The icon's side plus the focus ring's margin on both sides.
    var frameSide: CGFloat { Self.side + focusMargin * 2 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: frameSide, height: frameSide)
    }

    override var focusRingMaskBounds: NSRect {
        guard focusMargin > 0 else { return super.focusRingMaskBounds }
        return bounds.insetBy(dx: focusMargin, dy: focusMargin)
    }

    override func drawFocusRingMask() {
        guard focusMargin > 0 else { return super.drawFocusRingMask() }
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: HoverFillView.radius, yRadius: HoverFillView.radius)
            .fill()
    }

    /// The fill and icon are decoration: clicks on them belong to the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: focusMargin, dy: focusMargin)
        fill.frame = inner
        icon.frame = inner
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) { setHovered(true, animated: true) }
    override func mouseExited(with event: NSEvent) { setHovered(false, animated: true) }

    /// Pressed deepens the fill.
    override var isHighlighted: Bool {
        didSet { applyFill() }
    }

    /// A hidden button gets no exit event, so it drops its hover here.
    override func viewDidHide() {
        super.viewDidHide()
        setHovered(false, animated: false)
    }

    /// Shown under a still pointer (the row was highlighted by hover), it gets no enter
    /// event, so it reads the pointer here.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshHover(animated: true)
    }

    /// Reads the pointer again. A reused or moved cell's button gets no exit event, so its
    /// row calls this after laying it out.
    func refreshHover(animated: Bool) {
        guard !isHidden, let window else { return setHovered(false, animated: false) }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(bounds.contains(point), animated: animated)
    }

    /// The fill fades; Reduce Motion snaps it, as the picker rows do.
    private func setHovered(_ hovered: Bool, animated: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        applyTint()
        let alpha: CGFloat = hovered ? 1 : 0
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            fill.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.hoverDuration
            fill.animator().alphaValue = alpha
        }
    }

    /// A reused cell's button may still be showing another row's checkmark; new text
    /// drops it.
    func configure(text: String) {
        guard text != self.text else { return }
        self.text = text
        setCopied(false)
    }

    @objc func copyText() {
        Self.copyToPasteboard(text)
        setCopied(true)
        onCopy()
    }

    /// The checkmark alone, for a copy made elsewhere, such as a row's menu.
    func showCopied() {
        setCopied(true)
    }

    static func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func setCopied(_ copied: Bool) {
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        icon.image = copied ? Self.copiedImage : Self.copyImage
        guard copied else { return }
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: Self.feedbackDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setCopied(false) }
        }
    }

    /// On the accent the icon stays white and the fill alone shows the hover.
    private func applyTint() {
        icon.contentTintColor = isOnAccent ? .white : (isHovered ? .labelColor : .secondaryLabelColor)
    }

    /// The same tints as the rows' Pull and Push pills.
    private func applyFill() {
        let pressed = isHighlighted
        fill.color =
            isOnAccent
            ? NSColor.white.withAlphaComponent(pressed ? 0.36 : 0.22)
            : NSColor.labelColor.withAlphaComponent(pressed ? 0.16 : 0.09)
    }
}

/// The rounded fill behind the copy icon; drawn, so its colour follows the appearance.
private final class HoverFillView: NSView {
    static let radius: CGFloat = 4

    var color = NSColor.clear {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).fill()
    }
}
