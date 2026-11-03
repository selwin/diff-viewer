import AppKit

/// A branch row's pull request: the GitHub mark and `#n` in a capsule coloured by the pull
/// request's state. A click opens it on GitHub. At rest it is tinted; under the pointer, or
/// on the highlighted row, it fills solid with white content. The icon and number are
/// drawn rather than subviews, so every click lands on the button.
final class PullRequestCapsuleButton: NSButton {
    static let height: CGFloat = 18
    private static let padding: CGFloat = 7
    private static let iconSide: CGFloat = 11
    private static let iconGap: CGFloat = 4
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    private static let mark = NSImage(resource: .gitHubMark)

    /// Called with the pull request's page on a click or an accessibility press.
    var onOpen: ((URL) -> Void)?

    private(set) var pullRequest: ListedPullRequest?
    private var isHovered = false
    private var isRowHighlighted = false

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        isBordered = false
        title = ""
        // Like the row's other buttons: the search field keeps the keyboard.
        refusesFirstResponder = true
        // `.activeAlways`: a scripted launch never makes the popover key.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                userInfo: nil))
        target = self
        action = #selector(open)
        configure(pullRequest: nil, isRowHighlighted: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Called on every reuse. Nil hides the capsule and takes it out of the accessibility
    /// tree; a pull request drops any hover from the row the cell showed before.
    func configure(pullRequest: ListedPullRequest?, isRowHighlighted: Bool) {
        self.pullRequest = pullRequest
        self.isRowHighlighted = isRowHighlighted
        isHovered = false
        isHidden = pullRequest == nil
        setAccessibilityElement(pullRequest != nil)
        if let pullRequest {
            let state = Self.stateWord(pullRequest.state)
            toolTip = "Open \(state) pull request #\(pullRequest.number) on GitHub"
            setAccessibilityLabel("Pull request \(pullRequest.number), \(state)")
            setAccessibilityHelp("Opens on GitHub")
        } else {
            toolTip = nil
            setAccessibilityLabel(nil)
            setAccessibilityHelp(nil)
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// The row's highlight fills the capsule as the pointer does.
    func setRowHighlighted(_ highlighted: Bool) {
        guard highlighted != isRowHighlighted else { return }
        isRowHighlighted = highlighted
        needsDisplay = true
    }

    private static func stateWord(_ state: ListedPullRequest.State) -> String {
        switch state {
        case .open: "open"
        case .draft: "draft"
        case .merged: "merged"
        case .closed: "closed"
        }
    }

    // MARK: Size

    private var numberText: String { pullRequest.map { "#\($0.number)" } ?? "" }

    private var numberSize: NSSize {
        (numberText as NSString).size(withAttributes: [.font: Self.font])
    }

    /// The full width the row lays out; the capsule never truncates.
    var width: CGFloat {
        guard pullRequest != nil else { return 0 }
        return Self.padding * 2 + Self.iconSide + Self.iconGap + ceil(numberSize.width)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width, height: Self.height)
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// A hidden button gets no exit event, so it drops its hover here.
    override func viewDidHide() {
        super.viewDidHide()
        setHovered(false)
    }

    /// Shown under a still pointer, it gets no enter event, so it reads the pointer here.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshHover()
    }

    /// Reads the pointer again. A reused or moved cell's capsule gets no exit event, so its
    /// row calls this after laying it out.
    func refreshHover() {
        guard !isHidden, let window else { return setHovered(false) }
        setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let pullRequest, let context = NSGraphicsContext.current else { return }
        let colors = PullRequestCapsuleStyle.colors(for: pullRequest.state)
        let isFilled = isHovered || isRowHighlighted
        let content = isFilled ? PullRequestCapsuleStyle.hoverForeground : colors.foreground
        (isFilled ? colors.hoverFill : colors.tint).setFill()
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let iconRect = NSRect(
            x: Self.padding, y: (bounds.height - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide)
        // Replaces the template's colour rather than tinting over it.
        context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        Self.mark.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        content.setFill()
        iconRect.fill(using: .sourceIn)
        context.cgContext.endTransparencyLayer()

        // `#` and the digits are capital height, so their caps are centred, not the line box.
        let baseline = (bounds.height + Self.font.capHeight) / 2
        let origin = NSPoint(x: iconRect.maxX + Self.iconGap, y: baseline - Self.font.ascender)
        (numberText as NSString).draw(at: origin, withAttributes: [.font: Self.font, .foregroundColor: content])
    }

    // MARK: Opening

    @objc private func open() {
        guard let url = pullRequest?.url else { return }
        onOpen?(url)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .link }

    override func accessibilityPerformPress() -> Bool {
        guard pullRequest != nil, onOpen != nil else { return false }
        open()
        return true
    }
}
