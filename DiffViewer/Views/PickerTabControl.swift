import AppKit

/// Tabs drawn as a grey capsule track with the chosen tab raised inside it as a white
/// capsule, like the pickers' other raised controls. Each tab reads as a radio button, so
/// VoiceOver reads the group and which tab is chosen. The capsule slides to a newly
/// chosen tab.
@MainActor
final class PickerTabControl: NSView {
    static let height: CGFloat = 34
    /// Between the track's edge and the raised capsule; also the room for its shadow.
    private static let trackInset: CGFloat = 3
    private static let slideDuration: TimeInterval = 0.25

    /// Sent for a click on an enabled tab, chosen or not.
    var onSelect: (Int) -> Void = { _ in }

    /// Only the owner changes it: a click just reports the tab through `onSelect`.
    var selectedTabIndex = 0 {
        didSet {
            guard selectedTabIndex != oldValue else { return }
            updateButtonStates()
            slideSelection()
        }
    }

    private let buttons: [PickerTabButton]
    /// The raised capsule, under the buttons.
    private let selectionView = PickerTabSelectionView(margin: trackInset)
    /// While set, layout leaves the capsule to the animation.
    private var isSliding = false
    /// Bumped by each slide, so a slide cut short by the next can't end `isSliding` early.
    private var slideGeneration = 0

    /// Takes each tab's title and SF Symbol name.
    init(tabs: [(title: String, symbol: String)]) {
        buttons = tabs.map { PickerTabButton(title: $0.title, symbol: $0.symbol) }
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        addSubview(selectionView)
        for button in buttons {
            button.target = self
            button.action = #selector(tabClicked(_:))
            addSubview(button)
        }
        updateButtonStates()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Every tab as wide as the widest, as in a segmented control.
    override var intrinsicContentSize: NSSize {
        let widest = buttons.map(\.contentWidth).max() ?? 0
        return NSSize(width: widest * CGFloat(buttons.count) + Self.trackInset * 2, height: Self.height)
    }

    func setEnabled(_ enabled: Bool, forTab index: Int) {
        buttons[index].isEnabled = enabled
    }

    func setToolTip(_ toolTip: String?, forTab index: Int) {
        buttons[index].toolTip = toolTip
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() { button.frame = tabRect(index) }
        if !isSliding { selectionView.frame = selectionFrame }
    }

    private func updateButtonStates() {
        for (index, button) in buttons.enumerated() { button.state = index == selectedTabIndex ? .on : .off }
    }

    /// The chosen tab's rect, with room around it for the capsule's shadow.
    private var selectionFrame: NSRect {
        guard buttons.indices.contains(selectedTabIndex) else { return .zero }
        return tabRect(selectedTabIndex).insetBy(dx: -Self.trackInset, dy: -Self.trackInset)
    }

    /// Off screen, or with Reduce Motion, the capsule moves without sliding.
    private func slideSelection() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            needsLayout = true
            return
        }
        isSliding = true
        slideGeneration += 1
        let generation = slideGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            selectionView.animator().frame = selectionFrame
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.slideGeneration else { return }
                self.isSliding = false
                self.needsLayout = true
            }
        }
    }

    private func tabRect(_ index: Int) -> NSRect {
        let inner = bounds.insetBy(dx: Self.trackInset, dy: Self.trackInset)
        let width = inner.width / CGFloat(max(buttons.count, 1))
        return NSRect(x: inner.minX + width * CGFloat(index), y: inner.minY, width: width, height: inner.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        PickerStyle.controlFill.setFill()
        track.fill()
    }

    @objc private func tabClicked(_ sender: PickerTabButton) {
        guard let index = buttons.firstIndex(of: sender) else { return }
        onSelect(index)
    }

    /// Redraws with the current accessibility display options.
    func refreshRendering() {
        needsDisplay = true
        selectionView.needsDisplay = true
        for button in buttons { button.needsDisplay = true }
    }
}

/// The chosen tab's raised capsule, drawn `margin` inside the view to leave room for its
/// shadow.
@MainActor
private final class PickerTabSelectionView: NSView {
    private let margin: CGFloat

    init(margin: CGFloat) {
        self.margin = margin
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: margin, dy: margin)
        let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        // The brightest raised fill, so the chosen tab stands off the grey track.
        PickerStyle.drawRaised(capsule, fill: PickerStyle.raisedFill(.hover))
    }
}

/// One tab's symbol and title; the selection view draws the capsule behind it.
@MainActor
private final class PickerTabButton: NSButton {
    private static let font = PickerStyle.tabFont
    private static let symbolGap: CGFloat = 6
    private static let horizontalPadding: CGFloat = 16

    private let symbol: NSImage?

    init(title: String, symbol: String) {
        self.symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        super.init(frame: .zero)
        cell = PickerTabButtonCell()
        self.title = title
        clipsToBounds = true
        isBordered = false
        // Not `.radio`: a radio cell only takes clicks over its own left-aligned glyph and
        // title, not the whole tab. Momentary, so a click leaves `state` to the control.
        setButtonType(.momentaryPushIn)
        // The search field keeps the keyboard; ⇥ switches tabs.
        refusesFirstResponder = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var contentWidth: CGFloat {
        ceil(symbolSize.width + Self.symbolGap + titleString(color: .labelColor).size().width)
            + Self.horizontalPadding * 2
    }

    private var symbolSize: NSSize { symbol?.size ?? .zero }

    private func titleString(color: NSColor) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: color])
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        // A press on an unchosen tab darkens it until the control raises it.
        if isHighlighted, state == .off {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let color: NSColor = isEnabled ? .labelColor : .tertiaryLabelColor
        let string = titleString(color: color)
        let textSize = string.size()
        let iconSize = symbolSize
        var x = (bounds.width - iconSize.width - Self.symbolGap - textSize.width) / 2
        if let symbol {
            let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [color])) ?? symbol
            tinted.draw(
                in: NSRect(
                    x: x, y: (bounds.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconSize.width + Self.symbolGap
        }
        string.draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2))
    }
}

/// VoiceOver reads a button through its cell, so the tab's radio semantics live here.
private final class PickerTabButtonCell: NSButtonCell {
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }

    override func accessibilityValue() -> Any? { state == .on ? 1 : 0 }
}
