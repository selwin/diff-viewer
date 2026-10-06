import AppKit

/// The header both pickers share: a big title over a quiet subtitle, up to three accessory
/// views, and a hairline along the bottom. It draws no background, so the header and the
/// list share the popover's one surface.
///
/// Accessories are laid out by their visible shape (`alignmentRect`), so a view that
/// carries an invisible margin for its focus ring overrides `alignmentRectInsets` and
/// needs no allowance here. Each must report its size through `intrinsicContentSize`.
/// Owners hide an accessory with `isHidden`.
class PickerHeaderView: NSView {
    private typealias Metrics = PickerMetrics.Header

    /// The subtitle line's height for its font, measured once, so an empty subtitle still
    /// reserves its space and counts arriving later do not move the rows.
    private static let subtitleHeight: CGFloat = PickerViewGeometry.naturalSize(
        of: PickerLabel.make(font: Metrics.subtitleFont, color: .labelColor)
    ).height

    private let titleField: NSTextField
    private let subtitleField = PickerLabel.make(font: Metrics.subtitleFont, color: .secondaryLabelColor)
    private let wrapsTitle: Bool

    var title: String {
        get { titleField.stringValue }
        set {
            titleField.stringValue = newValue
            needsLayout = true
        }
    }

    var subtitle: String {
        get { subtitleField.stringValue }
        set {
            subtitleField.stringValue = newValue
            needsLayout = true
        }
    }

    var subtitleToolTip: String? {
        get { subtitleField.toolTip }
        set { subtitleField.toolTip = newValue }
    }

    /// Right after the title's text, centred on it. Meant for a single-line title.
    var titleAccessory: NSView? {
        didSet { swap(oldValue, for: titleAccessory) }
    }

    /// Whether the owner wants the title accessory; it is also hidden when there is no
    /// room for it, after the title has truncated as far as it can.
    var showsTitleAccessory = true {
        didSet { needsLayout = true }
    }

    /// Right after the subtitle's text, centred on the subtitle line. The subtitle truncates
    /// to keep it whole.
    var subtitleAccessory: NSView? {
        didSet { swap(oldValue, for: subtitleAccessory) }
    }

    /// On the trailing edge, centred on the title and subtitle together; they take the
    /// width that is left.
    var trailingAccessory: NSView? {
        didSet { swap(oldValue, for: trailingAccessory) }
    }

    /// A commit's subject can run long, so `wrapsTitle` lets it wrap in full; otherwise the
    /// title truncates on one line.
    init(wrapsTitle: Bool) {
        self.wrapsTitle = wrapsTitle
        if wrapsTitle {
            let field = NSTextField(wrappingLabelWithString: "")
            field.font = Metrics.titleFont
            field.textColor = .labelColor
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            field.isSelectable = false
            titleField = field
        } else {
            titleField = PickerLabel.make(font: Metrics.titleFont, color: .labelColor)
        }
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(titleField)
        addSubview(subtitleField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func swap(_ old: NSView?, for new: NSView?) {
        old?.removeFromSuperview()
        if let new { addSubview(new) }
        needsLayout = true
    }

    // MARK: Layout

    /// The title at `width`, the subtitle line, padding and the hairline.
    func fittingHeight(width: CGFloat) -> CGFloat {
        Metrics.topPadding + titleHeight(width: textWidth(forWidth: width)) + Metrics.titleSubtitleGap
            + Self.subtitleHeight + Metrics.bottomPadding + Metrics.dividerHeight
    }

    private var shownTrailing: NSView? {
        trailingAccessory.flatMap { $0.isHidden ? nil : $0 }
    }

    /// What the text block gets once the side padding and the trailing accessory are taken.
    private func textWidth(forWidth width: CGFloat) -> CGFloat {
        var available = width - Metrics.sidePadding * 2
        if let trailing = shownTrailing { available -= trailing.visibleSize.width + Metrics.trailingGap }
        return max(available, 0)
    }

    private func titleHeight(width: CGFloat) -> CGFloat {
        guard wrapsTitle else { return PickerViewGeometry.naturalSize(of: titleField).height }
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return ceil(titleField.cell?.cellSize(forBounds: bounds).height ?? 0)
    }

    override func layout() {
        super.layout()
        let width = textWidth(forWidth: bounds.width)
        let titleHeight = titleHeight(width: width)
        layoutTitle(width: width, height: titleHeight)
        let subtitleY = Metrics.topPadding + titleHeight + Metrics.titleSubtitleGap
        layoutSubtitle(y: subtitleY, width: width)
        if let trailing = shownTrailing {
            let centerY = Metrics.topPadding + (titleHeight + Metrics.titleSubtitleGap + Self.subtitleHeight) / 2
            trailing.placeVisible(x: bounds.width - Metrics.sidePadding - trailing.visibleSize.width, centerY: centerY)
        }
    }

    private func layoutTitle(width: CGFloat, height: CGFloat) {
        var titleWidth = width
        var showsAccessory = false
        if let accessory = titleAccessory {
            let accessoryWidth = accessory.visibleSize.width
            showsAccessory = showsTitleAccessory && width >= Metrics.titleAccessoryGap + accessoryWidth
            if showsAccessory {
                let natural = PickerViewGeometry.naturalSize(of: titleField).width
                titleWidth = max(min(natural, width - Metrics.titleAccessoryGap - accessoryWidth), 0)
            }
            accessory.isHidden = !showsAccessory
        }
        titleField.frame = NSRect(x: Metrics.sidePadding, y: Metrics.topPadding, width: titleWidth, height: height)
        if showsAccessory {
            titleAccessory?.placeVisible(
                x: titleField.frame.maxX + Metrics.titleAccessoryGap, centerY: titleField.frame.midY)
        }
    }

    /// With no subtitle accessory the subtitle spans its space whatever it says.
    private func layoutSubtitle(y: CGFloat, width: CGFloat) {
        var subtitleWidth = width
        let accessory = subtitleAccessory.flatMap { $0.isHidden ? nil : $0 }
        if let accessory {
            let natural = PickerViewGeometry.naturalSize(of: subtitleField).width
            subtitleWidth = min(natural, max(width - accessory.visibleSize.width, 0))
        }
        subtitleField.frame = NSRect(x: Metrics.sidePadding, y: y, width: subtitleWidth, height: Self.subtitleHeight)
        accessory?.placeVisible(x: subtitleField.frame.maxX, centerY: subtitleField.frame.midY)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - Metrics.dividerHeight, width: bounds.width, height: Metrics.dividerHeight)
            .fill()
    }
}

extension NSView {
    /// The size of the view's visible shape, without any margin `alignmentRectInsets` removes.
    var visibleSize: NSSize {
        alignmentRect(forFrame: NSRect(origin: .zero, size: intrinsicContentSize)).size
    }

    /// Sets the frame so the visible shape starts at `x` and is centred on `centerY`, both in
    /// the superview's coordinates. Returns where the visible shape ends.
    @discardableResult
    func placeVisible(x: CGFloat, centerY: CGFloat) -> CGFloat {
        let size = visibleSize
        let visible = NSRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
        let target = frame(forAlignmentRect: visible)
        frame = superview?.backingAlignedRect(target, options: PickerViewGeometry.pixelAlignment) ?? target
        return x + size.width
    }
}
