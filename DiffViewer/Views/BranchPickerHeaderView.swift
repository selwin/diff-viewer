import AppKit

/// The branch picker's header: where HEAD is, with a copy button after a branch's name, a
/// subtitle for how far that branch is from its upstream and how the fetch went, a round
/// Fetch button that spins while a round runs, and the current branch's Pull and Push
/// after it.
final class BranchPickerHeaderView: PickerHeaderView {
    // Focusable like the header's other controls, so it carries room for its ring.
    private let copyButton = PickerCopyButton(label: "Copy Branch Name", focusMargin: SyncPillButton.focusRingMargin)
    private let controls = BranchHeaderControls()
    private var syncButtons: BranchRowSyncButtons { controls.syncButtons }
    private var fetchButton: FetchButton { controls.fetchButton }

    /// After a copy; the picker returns focus to its search field.
    var onCopy: () -> Void {
        get { copyButton.onCopy }
        set { copyButton.onCopy = newValue }
    }
    var onFetch: () -> Void = {}
    var onPull: (String) -> Void = { _ in }
    var onPush: (String) -> Void = { _ in }
    /// Takes the branch, then the remote to publish it to.
    var onPublish: (String, String) -> Void = { _, _ in }
    private var text = BranchPickerHeaderText(title: "")

    init() {
        super.init(wrapsTitle: false)
        fetchButton.target = self
        fetchButton.action = #selector(fetchClicked)
        titleAccessory = copyButton
        trailingAccessory = controls
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `fetch` follows the upstream on the subtitle, and its tooltip covers the line.
    func configure(_ text: BranchPickerHeaderText, fetch: BranchPickerFetchText?) {
        self.text = text
        title = text.title
        showsTitleAccessory = text.copyableName != nil
        if let name = text.copyableName { copyButton.configure(text: name) }
        configureFetch(fetch)
        fetchButton.isEnabled = text.canFetch
        fetchButton.isSpinning = text.showsSpinner
        if let branch = text.branch {
            syncButtons.configure(
                text.buttons, isRevealed: true, branch: branch,
                onPull: { [weak self] in self?.onPull($0) }, onPush: { [weak self] in self?.onPush($0) },
                onPublish: { [weak self] in self?.onPublish($0, $1) }, onDelete: {})
            syncButtons.isHidden = !syncButtons.shouldShow
        } else {
            syncButtons.isHidden = true
        }
        controls.needsLayout = true
        needsLayout = true
    }

    /// Updates only the subtitle, as the fetch time ages.
    func configureFetch(_ fetch: BranchPickerFetchText?) {
        subtitle = text.detail(fetch: fetch)
        subtitleToolTip = fetch?.tooltip
    }

    @objc private func fetchClicked() {
        onFetch()
    }

    /// ⇧⌘P on the current branch's Pull, through its click. Returns whether it ran.
    func pressPull() -> Bool {
        syncButtons.pressPull()
    }

    /// ⌘P on the current branch's Push or Publish, as for `pressPull`.
    func pressPush() -> Bool {
        syncButtons.pressPush()
    }

    func setShortcutGlyphs(pull: Bool, push: Bool) {
        syncButtons.setShortcutGlyphs(pull: pull, push: push)
    }

    /// The header's controls for `order`, which the container chains after the search field.
    func keyViews(for order: [BranchPickerHeaderText.Control]) -> [NSView] {
        order.map { control in
            switch control {
            case .copy: copyButton
            case .fetch: fetchButton
            case .pull: syncButtons.pullButton
            case .push: syncButtons.pushButton
            }
        }
    }
}

/// The round Fetch button and, when the current branch has them, its Pull and Push, side by
/// side as the header's one trailing accessory. Its frame carries the focus ring margin
/// of the buttons at its ends.
private final class BranchHeaderControls: NSView {
    private static let controlGap: CGFloat = 8
    private static let margin = SyncPillButton.focusRingMargin

    let fetchButton = FetchButton(frame: .zero)
    let syncButtons = BranchRowSyncButtons(style: .header)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        // Fetch comes first, left of Pull and Push, in the order Tab visits them.
        addSubview(fetchButton)
        addSubview(syncButtons)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
    }

    override var intrinsicContentSize: NSSize {
        var width = fetchButton.visibleSize.width
        if !syncButtons.isHidden { width += Self.controlGap + syncButtons.visibleSize.width }
        return NSSize(width: width + Self.margin * 2, height: fetchButton.intrinsicContentSize.height)
    }

    override func layout() {
        super.layout()
        let centerY = bounds.height / 2
        let fetchMaxX = fetchButton.placeVisible(x: Self.margin, centerY: centerY)
        if !syncButtons.isHidden {
            syncButtons.placeVisible(x: fetchMaxX + Self.controlGap, centerY: centerY)
        }
    }
}

/// A round button with a symbol that turns while a fetch runs.
final class FetchButton: NSButton {
    private static let side: CGFloat = 28
    /// The circle plus room for its focus ring, which would otherwise be clipped.
    static let frameSide = side + SyncPillButton.focusRingMargin * 2

    private let symbol = NSImageView()

    /// Also shown as disabled: a round is already running.
    var isSpinning = false {
        didSet {
            guard isSpinning != oldValue else { return }
            if isSpinning {
                symbol.addSymbolEffect(.rotate, options: .repeating)
            } else {
                symbol.removeAllSymbolEffects()
            }
            applyTint()
        }
    }

    override var isEnabled: Bool {
        didSet { applyTint() }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isBordered = false
        title = ""
        // Takes focus for keyboard users, like the header's Pull and Push.
        focusRingType = .default
        toolTip = "Fetch (⌘R)"
        setAccessibilityLabel("Fetch")
        symbol.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        symbol.imageScaling = .scaleNone
        addSubview(symbol)
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The symbol is decoration: clicks on it belong to the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.frameSide, height: Self.frameSide)
    }

    private var circle: NSBezierPath {
        NSBezierPath(ovalIn: focusRingMaskBounds)
    }

    /// The visible circle, without the focus ring's margin.
    override var alignmentRectInsets: NSEdgeInsets {
        let margin = SyncPillButton.focusRingMargin
        return NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
    }

    override var focusRingMaskBounds: NSRect {
        let inset = SyncPillButton.focusRingMargin
        return bounds.insetBy(dx: inset, dy: inset)
    }

    override func drawFocusRingMask() {
        circle.fill()
    }

    private func applyTint() {
        symbol.contentTintColor = isEnabled || isSpinning ? .secondaryLabelColor : .tertiaryLabelColor
    }

    override func layout() {
        super.layout()
        symbol.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.07).setFill()
        circle.fill()
    }
}
