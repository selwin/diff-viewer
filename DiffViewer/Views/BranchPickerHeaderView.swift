import AppKit

/// The branch picker's header: where HEAD is, with a copy button after a branch's name, a
/// detail line for how far that branch is from its upstream and how the fetch went, a
/// round Fetch button that spins while a round runs, and the current branch's Pull and
/// Push after it. It draws no background of its own, so the header and the list share the
/// popover's one surface.
final class BranchPickerHeaderView: NSView {
    private typealias Metrics = PickerMetrics.Header

    private static let controlGap: CGFloat = 8
    /// Between the title and the copy button, whose hover fill already pads the icon.
    private static let copyGap: CGFloat = 2

    private let title = PickerLabel.make(font: Metrics.titleFont, color: .labelColor)
    // Focusable like the header's other controls, so it carries room for its ring.
    private let copyButton = PickerCopyButton(label: "Copy Branch Name", focusMargin: SyncPillButton.focusRingMargin)
    private let detail = PickerLabel.make(font: Metrics.detailFont, color: .secondaryLabelColor)
    private let syncButtons = BranchRowSyncButtons(style: .header)
    private let fetchButton = FetchButton(frame: .zero)

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

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        fetchButton.target = self
        fetchButton.action = #selector(fetchClicked)
        for view in [title, copyButton, detail, syncButtons, fetchButton] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// `fetch` follows the upstream on the detail line, and its tooltip covers the line.
    func configure(_ text: BranchPickerHeaderText, fetch: BranchPickerFetchText?) {
        self.text = text
        title.stringValue = text.title
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
        needsLayout = true
    }

    /// Redraws only the fetch text. The detail line's frame spans its space whatever it
    /// says, so this needs no layout.
    func configureFetch(_ fetch: BranchPickerFetchText?) {
        detail.stringValue = text.detail(fetch: fetch)
        detail.toolTip = fetch?.tooltip
    }

    @objc private func fetchClicked() {
        onFetch()
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

    /// Two text lines and padding; constant so counts arriving later do not move the rows.
    var fittingHeight: CGFloat {
        Metrics.topPadding + PickerViewGeometry.naturalSize(of: title).height + Metrics.lineGap
            + Self.detailHeight + Metrics.bottomPadding
    }

    /// The detail line's height for its font, measured once, so an empty line still
    /// reserves its space.
    private static let detailHeight: CGFloat = PickerViewGeometry.naturalSize(
        of: PickerLabel.make(font: Metrics.detailFont, color: .labelColor)
    ).height

    override func layout() {
        super.layout()
        let titleHeight = PickerViewGeometry.naturalSize(of: title).height
        let centerY =
            (Metrics.topPadding + titleHeight + Metrics.lineGap + Self.detailHeight + Metrics.topPadding) / 2
        // The controls on the trailing edge are placed first; the text takes what is left.
        var trailing = bounds.width - Metrics.sidePadding
        // Both controls carry a margin for their focus rings; the gaps are between the shapes.
        let margin = SyncPillButton.focusRingMargin
        // Fetch comes first, left of Pull and Push, in the order Tab visits them.
        if !syncButtons.isHidden {
            let size = syncButtons.intrinsicContentSize
            syncButtons.frame = NSRect(
                x: trailing - size.width + margin, y: (centerY - size.height / 2).rounded(), width: size.width,
                height: size.height)
            trailing = syncButtons.frame.minX + margin - Self.controlGap
        }
        let fetchSide = FetchButton.frameSide
        fetchButton.frame = NSRect(
            x: trailing - fetchSide + margin, y: (centerY - fetchSide / 2).rounded(), width: fetchSide,
            height: fetchSide)
        trailing = fetchButton.frame.minX + margin - Self.controlGap
        let textWidth = max(trailing - Metrics.sidePadding, 0)
        layoutTitle(width: textWidth, height: titleHeight)
        detail.frame = NSRect(
            x: Metrics.sidePadding, y: title.frame.maxY + Metrics.lineGap, width: textWidth,
            height: Self.detailHeight)
    }

    /// The title, truncating, then the copy button, which is hidden when there's nothing to
    /// copy or no room for it.
    private func layoutTitle(width: CGFloat, height: CGFloat) {
        let side = PickerCopyButton.side
        let showsCopy = text.copyableName != nil && width >= Self.copyGap + side
        let naturalWidth = PickerViewGeometry.naturalSize(of: title).width
        let titleWidth = showsCopy ? max(min(naturalWidth, width - Self.copyGap - side), 0) : width
        title.frame = NSRect(x: Metrics.sidePadding, y: Metrics.topPadding, width: titleWidth, height: height)
        copyButton.isHidden = !showsCopy
        let frameSide = copyButton.frameSide
        copyButton.frame = backingAlignedRect(
            NSRect(
                x: title.frame.maxX + Self.copyGap - copyButton.focusMargin, y: title.frame.midY - frameSide / 2,
                width: frameSide, height: frameSide),
            options: PickerViewGeometry.pixelAlignment)
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
