import AppKit

/// A capsule button drawn by hand, so its fill and text follow its surface and look.
final class PickerPillButton: NSButton {
    /// What the capsule is drawn as.
    enum Surface {
        /// A quiet grey fill, for row pills.
        case neutral
        /// A raised white capsule with a hover fill, for the header.
        case raised
    }

    /// The title's colour.
    enum Look {
        case plain
        /// Accent text.
        case primary
        /// Red text.
        case destructive
    }

    private static let font = PickerStyle.pillFont
    /// The shortcut glyph after the title: a size smaller and faded, as on the commit sheet.
    private static let shortcutFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let shortcutGap: CGFloat = 5
    private static let shortcutOpacity: CGFloat = 0.6
    /// Room around a focusable button's capsule, so its focus ring isn't clipped.
    static let focusRingMargin: CGFloat = 4

    private let height: CGFloat
    private let focusMargin: CGFloat
    private let surface: Surface
    private let horizontalPadding: CGFloat
    private let spinner = NSProgressIndicator(frame: .zero)
    private var isRunning = false
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    /// The key this button's action answers to. Its width is reserved while
    /// `reservesShortcutWidth` is set, so the button keeps its size as the glyph comes and
    /// goes.
    var shortcut: String? {
        didSet {
            guard shortcut != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
            needsDisplay = true
        }
    }

    /// Whether the glyph is drawn: only on the button the key would press now.
    var showsKeyboardShortcut = false {
        didSet {
            if showsKeyboardShortcut != oldValue { needsDisplay = true }
        }
    }

    /// Off, the shortcut's room is given up and its glyph is never drawn.
    var reservesShortcutWidth = true {
        didSet {
            guard reservesShortcutWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var look = Look.plain {
        didSet { if look != oldValue { needsDisplay = true } }
    }

    init(title: String, height: CGFloat, focusMargin: CGFloat, surface: Surface) {
        self.height = height
        self.focusMargin = focusMargin
        self.surface = surface
        horizontalPadding = surface == .raised ? 14 : 10
        super.init(frame: .zero)
        self.title = title
        clipsToBounds = true
        isBordered = false
        setButtonType(.momentaryPushIn)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        if surface == .raised {
            // `.activeAlways`: a scripted launch never makes the popover key.
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                    userInfo: nil))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Sized with the title in place, so a running button keeps its width.
    override var intrinsicContentSize: NSSize {
        NSSize(width: width(reservingShortcut: reservesShortcutWidth), height: height + focusMargin * 2)
    }

    /// The frame's width with or without the shortcut's room.
    func width(reservingShortcut: Bool) -> CGFloat {
        var width = ceil(NSAttributedString(string: title, attributes: [.font: Self.font]).size().width)
        if reservingShortcut, let shortcut {
            width += Self.shortcutGap + ceil(Self.shortcutString(shortcut, color: .labelColor).size().width)
        }
        return width + horizontalPadding * 2 + focusMargin * 2
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A hidden button gets no exit event.
    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    private var capsule: NSBezierPath {
        let rect = bounds.insetBy(dx: focusMargin, dy: focusMargin)
        return NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    }

    override var focusRingMaskBounds: NSRect {
        bounds.insetBy(dx: focusMargin, dy: focusMargin)
    }

    override func drawFocusRingMask() {
        capsule.fill()
    }

    func apply(_ state: PickerButtonState, title: String) {
        if self.title != title {
            self.title = title
            invalidateIntrinsicContentSize()
        }
        isHidden = state == .hidden
        isEnabled = state == .enabled
        toolTip = if case let .disabled(reason) = state { reason } else { nil }
        isRunning = state == .running
        setAccessibilityLabel(isRunning ? "\(title), in progress" : title)
        updateSpinner()
        needsLayout = true
        needsDisplay = true
    }

    /// Spins only while running and on screen: a row removed mid-operation leaves the
    /// window once its fade ends, and its spinner must not keep going in the reuse queue.
    private func updateSpinner() {
        if isRunning, window != nil {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpinner()
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 16
        spinner.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        let isActive = isEnabled || isRunning
        switch surface {
        case .raised:
            let state: PickerStyle.Raised =
                !isActive ? .rest : isHighlighted ? .pressed : isHovered ? .hover : .rest
            PickerStyle.drawRaised(capsule, fill: PickerStyle.raisedFill(state))
        case .neutral:
            (isActive ? PickerStyle.controlFill : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
            capsule.fill()
            if isActive, isHighlighted {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                capsule.fill()
            }
        }
        let text = textColor
        guard !isRunning else { return }
        let string = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: text])
        let size = string.size()
        // Without the glyph, the title centres alone in the reserved width.
        guard showsKeyboardShortcut, reservesShortcutWidth, let shortcut else {
            string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
            return
        }
        let glyph = Self.shortcutString(shortcut, color: text.withAlphaComponent(Self.shortcutOpacity))
        let glyphSize = glyph.size()
        let x = (bounds.width - size.width - Self.shortcutGap - glyphSize.width) / 2
        string.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
        glyph.draw(at: NSPoint(x: x + size.width + Self.shortcutGap, y: (bounds.height - glyphSize.height) / 2))
    }

    private static func shortcutString(_ shortcut: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: shortcut, attributes: [.font: shortcutFont, .foregroundColor: color])
    }

    private var textColor: NSColor {
        guard isEnabled || isRunning else { return .tertiaryLabelColor }
        switch look {
        case .plain: return .labelColor
        case .primary: return PickerStyle.accent
        case .destructive: return .systemRed
        }
    }

    /// Redraws with the current accessibility display options.
    func refreshRendering() {
        needsDisplay = true
    }
}
