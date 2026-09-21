import AppKit

/// The Working Tree row, pinned above the table. Draws its own fill: a quiet capsule at
/// rest, a step darker under the pointer, the table's highlight fill when highlighted.
/// A click activates it on release; a drag out of the content cancels.
final class CommitPickerPinnedRowView: NSView {
    private let content = ScopeRowContentView(frame: .zero)
    private var trackingArea: NSTrackingArea?
    private var isPressed = false
    var onActivate: () -> Void = {}

    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            setAccessibilitySelected(isHighlighted)
            needsDisplay = true
        }
    }

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(content)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Working Tree")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(trailing: String, showsPill: Bool) {
        content.configure(
            ScopeRowContentView.Content(
                gutterTitle: "Now", gutterSubtitle: nil, subject: "Working Tree", showsCurrentPill: showsPill,
                trailing: trailing, trailingStyle: .secondary, accessibilityActionName: "Show"))
        setAccessibilityValue(trailing)
    }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: CommitPickerMetrics.contentRect(in: bounds), xRadius: CommitPickerMetrics.cornerRadius,
            yRadius: CommitPickerMetrics.cornerRadius)
        if isHighlighted {
            CommitPickerMetrics.highlightColor.setFill()
            path.fill()
            return
        }
        NSColor.quaternarySystemFill.setFill()
        path.fill()
        if isHovered { path.fill() }
    }

    // MARK: Input

    /// The gutter ("Now") is not part of the row, as in the table.
    private func isInContent(_ event: NSEvent) -> Bool {
        convert(event.locationInWindow, from: nil).x >= CommitPickerMetrics.gutterWidth
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = isInContent(event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        let point = convert(event.locationInWindow, from: nil)
        guard isPressed, bounds.contains(point), point.x >= CommitPickerMetrics.gutterWidth else { return }
        onActivate()
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = isInContent(event)
    }

    override func mouseMoved(with event: NSEvent) {
        isHovered = isInContent(event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
}
