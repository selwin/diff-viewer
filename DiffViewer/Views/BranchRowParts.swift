import AppKit

/// A branch row's round icon tile: a grey circle with the branch glyph, a cloud for a
/// remote-only branch, or an accent-tinted circle with a checkmark for the current one.
/// The circle is drawn, so its dynamic colours follow the appearance.
final class BranchRowIconTile: NSView {
    private let glyph = NSImageView()
    private var isCurrent = false
    /// Symbols at their natural size; the branch asset is scaled to 14pt.
    private var glyphSize = NSSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        glyph.imageScaling = .scaleProportionallyUpOrDown
        addSubview(glyph)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(kind: BranchPickerRow.Kind) {
        isCurrent = kind == .current
        switch kind {
        case .current:
            glyph.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
            glyph.contentTintColor = BranchPickerStyle.accent
        case .remoteOnly:
            glyph.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            glyph.contentTintColor = .secondaryLabelColor
        case .local:
            glyph.image = NSImage(resource: .gitBranch)
            glyph.contentTintColor = .secondaryLabelColor
        }
        glyphSize = kind == .local ? NSSize(width: 14, height: 14) : glyph.image?.size ?? .zero
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        glyph.frame = backingAlignedRect(
            NSRect(
                x: (bounds.width - glyphSize.width) / 2, y: (bounds.height - glyphSize.height) / 2,
                width: glyphSize.width, height: glyphSize.height),
            options: PickerViewGeometry.pixelAlignment)
    }

    override func draw(_ dirtyRect: NSRect) {
        (isCurrent ? BranchPickerStyle.accentTint : BranchPickerStyle.tileFill).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// A row's right-edge words, such as its upstream status or a Merge preview, in their
/// style's colour. A deleted upstream leads with a slashed link.
final class BranchRowStatusView: NSView {
    private static let iconSide: CGFloat = 12
    private static let iconGap: CGFloat = 3

    private let label = PickerLabel.make(
        font: BranchPickerStyle.rowStatusFont, color: BranchPickerStyle.meta, alignment: .right)
    private let icon = SlashedLinkIcon(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(icon)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var text: String { label.stringValue }

    func configure(_ status: BranchRowLabel?) {
        label.stringValue = status?.text ?? ""
        let style = status?.style ?? .secondary
        label.textColor =
            switch style {
            case .secondary, .upstreamGone: BranchPickerStyle.meta
            case .accent: BranchPickerStyle.accent
            case .warning: BranchPickerStyle.warning
            }
        icon.isHidden = style != .upstreamGone
        toolTip = style == .upstreamGone ? "Upstream branch was deleted" : nil
        needsLayout = true
    }

    var naturalSize: NSSize {
        let text = PickerViewGeometry.naturalSize(of: label)
        guard !label.stringValue.isEmpty else { return .zero }
        let iconWidth = icon.isHidden ? 0 : Self.iconSide + Self.iconGap
        return NSSize(width: ceil(text.width + iconWidth), height: ceil(text.height))
    }

    /// The icon stays whole; the words truncate.
    override func layout() {
        super.layout()
        let height = PickerViewGeometry.naturalSize(of: label).height
        let iconWidth = icon.isHidden ? 0 : Self.iconSide + Self.iconGap
        icon.frame = NSRect(
            x: 0, y: ((bounds.height - Self.iconSide) / 2).rounded(), width: Self.iconSide, height: Self.iconSide)
        label.frame = NSRect(
            x: iconWidth, y: (bounds.height - height) / 2, width: max(bounds.width - iconWidth, 0), height: height)
    }

    func refreshRendering() {
        icon.needsDisplay = true
    }
}

/// SF Symbols has no slashed link yet, so one is drawn: the link, cut by a slash, in the
/// status grey. `link.slash` is used instead if a later release adds it.
private final class SlashedLinkIcon: NSView {
    private static let slashed = NSImage(systemSymbolName: "link.slash", accessibilityDescription: nil)
    private static let link = NSImage(systemSymbolName: "link", accessibilityDescription: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = (Self.slashed ?? Self.link)?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)),
            let context = NSGraphicsContext.current
        else { return }
        let size = image.size
        let rect = NSRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width,
            height: size.height)
        context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect)
        BranchPickerStyle.meta.setFill()
        bounds.fill(using: .sourceAtop)
        if Self.slashed == nil {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: bounds.minX + 1.5, y: bounds.minY + 1.5))
            slash.line(to: NSPoint(x: bounds.maxX - 1.5, y: bounds.maxY - 1.5))
            slash.lineCapStyle = .round
            // A gap either side of the slash, so it reads as cutting the link.
            context.compositingOperation = .destinationOut
            slash.lineWidth = 3.2
            slash.stroke()
            context.compositingOperation = .sourceOver
            slash.lineWidth = 1.3
            BranchPickerStyle.meta.setStroke()
            slash.stroke()
        }
        context.cgContext.endTransparencyLayer()
    }
}
