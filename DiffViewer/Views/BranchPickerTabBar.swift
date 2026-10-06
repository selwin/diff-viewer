import AppKit

/// The branch picker's tab band under the header: Switch and Merge…. The selected tab is
/// filled with the sheet's colour and opens into the sheet below, like a folder tab.
/// Tabs never take focus: the search field keeps the keyboard.
final class BranchPickerTabBar: NSView {
    /// The sheet under the tabs, which the selected tab joins.
    static let sheetColor = NSColor.controlBackgroundColor
    static let tabHeight: CGFloat = 30
    private static let topPadding: CGFloat = 8
    private static let sidePadding: CGFloat = 10
    private static let tabGap: CGFloat = 4
    static let height = topPadding + tabHeight

    var onSelect: (BranchPickerTab) -> Void = { _ in }

    private let switchTab = BranchPickerTabButton(
        tab: .switchBranch, title: "Switch", symbol: "arrow.left.arrow.right")
    private let mergeTab = BranchPickerTabButton(tab: .merge, title: "Merge…", symbol: "arrow.triangle.merge")

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        for tab in [switchTab, mergeTab] {
            tab.onPress = { [weak self] tab in self?.onSelect(tab) }
            addSubview(tab)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Branch action")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(selected: BranchPickerTab, isMergeAvailable: Bool) {
        switchTab.isSelected = selected == .switchBranch
        mergeTab.isSelected = selected == .merge
        mergeTab.isEnabled = isMergeAvailable
        mergeTab.toolTip = isMergeAvailable ? nil : "Check out a branch to merge into it"
    }

    override func accessibilityChildren() -> [Any]? {
        [switchTab, mergeTab]
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        bounds.fill()
    }

    override func layout() {
        super.layout()
        let width = (bounds.width - Self.sidePadding * 2 - Self.tabGap) / 2
        switchTab.frame = NSRect(x: Self.sidePadding, y: Self.topPadding, width: width, height: Self.tabHeight)
        mergeTab.frame = NSRect(
            x: switchTab.frame.maxX + Self.tabGap, y: Self.topPadding, width: width, height: Self.tabHeight)
    }
}

/// One tab: a symbol and a title, centred. Acts on release inside, like a button.
private final class BranchPickerTabButton: NSView {
    private static let cornerRadius: CGFloat = 8
    private static let iconGap: CGFloat = 5
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    let tab: BranchPickerTab
    var onPress: (BranchPickerTab) -> Void = { _ in }

    var isSelected = false {
        didSet { if isSelected != oldValue { applyState() } }
    }
    var isEnabled = true {
        didSet { if isEnabled != oldValue { applyState() } }
    }

    private let icon = NSImageView()
    private let title = PickerLabel.make(font: font, color: .secondaryLabelColor)
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    init(tab: BranchPickerTab, title text: String, symbol: String) {
        self.tab = tab
        super.init(frame: .zero)
        clipsToBounds = true
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .medium))
        icon.imageScaling = .scaleNone
        title.stringValue = text
        for view in [icon, title] { addSubview(view) }
        // `.activeAlways`: a scripted launch never makes the popover key.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(text)
        applyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The first click in an inactive popover acts, as a row's does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The icon and title are decoration: clicks on them belong to the tab.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !isSelected else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, !isSelected else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        if wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) { onPress(tab) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress(tab)
        return true
    }

    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }
    override func isAccessibilitySelected() -> Bool { isSelected }

    private func applyState() {
        let color: NSColor =
            !isEnabled ? .tertiaryLabelColor : isSelected ? .labelColor : .secondaryLabelColor
        title.textColor = color
        icon.contentTintColor = color
        needsDisplay = true
    }

    /// Selected: the sheet's colour with a hairline over the top and down the sides, open
    /// at the bottom so it runs into the sheet. Otherwise a faint fill under the pointer.
    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            let radius = Self.cornerRadius
            let path = NSBezierPath()
            let rect = bounds.insetBy(dx: 0.5, dy: 0)
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + 0.5 + radius))
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + 0.5 + radius), radius: radius,
                startAngle: 180, endAngle: 270)
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY + 0.5))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + 0.5 + radius), radius: radius,
                startAngle: 270, endAngle: 360)
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            BranchPickerTabBar.sheetColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if isEnabled, isHovered || isPressed {
            NSColor.labelColor.withAlphaComponent(isPressed ? 0.08 : 0.04).setFill()
            let rect = bounds.insetBy(dx: 0, dy: 2)
            NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius - 2, yRadius: Self.cornerRadius - 2).fill()
        }
    }

    override func layout() {
        super.layout()
        let iconSize = icon.image?.size ?? .zero
        let titleSize = PickerViewGeometry.naturalSize(of: title)
        let contentWidth = min(iconSize.width + Self.iconGap + titleSize.width, bounds.width)
        let x = ((bounds.width - contentWidth) / 2).rounded()
        icon.frame = NSRect(
            x: x, y: ((bounds.height - iconSize.height) / 2).rounded(), width: iconSize.width,
            height: iconSize.height)
        let titleX = icon.frame.maxX + Self.iconGap
        title.frame = NSRect(
            x: titleX, y: ((bounds.height - titleSize.height) / 2).rounded(),
            width: max(min(titleSize.width, bounds.width - titleX), 0), height: titleSize.height)
    }
}

/// The sheet under the tabs, behind the instruction, search field and list.
final class BranchPickerSheetView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        BranchPickerTabBar.sheetColor.setFill()
        bounds.fill()
    }
}
