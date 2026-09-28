import AppKit

/// The branch picker's header: where HEAD is, a detail line for how far that branch is from
/// its upstream and how the fetch went, a round Fetch button that spins while a round runs,
/// and the current branch's Pull and Push after it. It draws no background of its own, so the
/// header and the list share the popover's one surface.
final class BranchPickerHeaderView: NSView {
    private static let topPadding: CGFloat = 13
    private static let sidePadding: CGFloat = 16
    private static let bottomPadding: CGFloat = 4
    private static let lineGap: CGFloat = 2
    private static let controlGap: CGFloat = 8

    private let title = CommitPickerMetrics.label(font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
    private let detail = CommitPickerMetrics.label(font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let syncButtons = BranchRowSyncButtons(style: .header)
    private let fetchButton = FetchButton(frame: .zero)

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
        for view in [title, detail, syncButtons, fetchButton] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// `fetch` follows the upstream on the detail line, and its tooltip covers the line.
    func configure(_ text: BranchPickerHeaderText, fetch: BranchPickerFetchText?) {
        self.text = text
        title.stringValue = text.title
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
            case .fetch: fetchButton
            case .pull: syncButtons.pullButton
            case .push: syncButtons.pushButton
            }
        }
    }

    /// Two text lines and padding; constant so counts arriving later do not move the rows.
    var fittingHeight: CGFloat {
        Self.topPadding + CommitPickerMetrics.naturalSize(of: title).height + Self.lineGap + Self.detailHeight
            + Self.bottomPadding
    }

    /// The detail line's height for its font, measured once, so an empty line still
    /// reserves its space.
    private static let detailHeight: CGFloat = CommitPickerMetrics.naturalSize(
        of: CommitPickerMetrics.label(font: .systemFont(ofSize: 12), color: .labelColor)
    ).height

    override func layout() {
        super.layout()
        let titleHeight = CommitPickerMetrics.naturalSize(of: title).height
        let centerY = (Self.topPadding + titleHeight + Self.lineGap + Self.detailHeight + Self.topPadding) / 2
        // The controls on the trailing edge are placed first; the text takes what is left.
        var trailing = bounds.width - Self.sidePadding
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
        let textWidth = max(trailing - Self.sidePadding, 0)
        title.frame = NSRect(x: Self.sidePadding, y: Self.topPadding, width: textWidth, height: titleHeight)
        detail.frame = NSRect(
            x: Self.sidePadding, y: title.frame.maxY + Self.lineGap, width: textWidth, height: Self.detailHeight)
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
