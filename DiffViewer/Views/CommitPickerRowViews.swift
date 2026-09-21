import AppKit

/// Shared geometry of the commit picker: the gutter on the left, then a content area
/// the row highlights and text keep to.
enum CommitPickerMetrics {
    static let gutterWidth: CGFloat = 106
    static let gutterTrailingInset: CGFloat = 14
    /// Where the content area starts, and how far it stops short of the right edge.
    static let contentLeading: CGFloat = gutterWidth + 8
    static let contentTrailing: CGFloat = 16
    /// Text inset inside the content area.
    static let textInset: CGFloat = 12
    static let rowHeight: CGFloat = 38
    static let rowGap: CGFloat = 1
    static let cornerRadius: CGFloat = 7
    static let footerHeight: CGFloat = 30

    static func contentRect(in bounds: NSRect) -> NSRect {
        NSRect(
            x: contentLeading, y: bounds.minY, width: bounds.width - contentLeading - contentTrailing,
            height: bounds.height)
    }

    static func label(font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    /// A truncating label's `intrinsicContentSize` is capped by its current frame; the
    /// cell's size is the text's natural size.
    static func naturalSize(of field: NSTextField) -> NSSize {
        field.cell?.cellSize ?? .zero
    }

    /// The highlighted row's fill: neutral, and clearly stronger than the hover fill
    /// and the pinned row's resting fill (both quaternary).
    static let highlightColor = NSColor.secondarySystemFill
    static let hoverColor = NSColor.quaternarySystemFill

    /// The vertical centre of `field`'s capitals, in its (flipped) superview's coordinates.
    static func capCenterY(of field: NSTextField) -> CGFloat {
        field.frame.minY + field.firstBaselineOffsetFromTop - capHeight(of: field) / 2
    }

    /// The y that puts `field`'s capitals centred on `centerY`.
    static func y(centering field: NSTextField, on centerY: CGFloat) -> CGFloat {
        centerY + capHeight(of: field) / 2 - field.firstBaselineOffsetFromTop
    }

    private static func capHeight(of field: NSTextField) -> CGFloat {
        (field.font ?? .systemFont(ofSize: NSFont.systemFontSize)).capHeight
    }

    /// Pixel alignment that never shrinks a label into truncating.
    static let pixelAlignment: AlignmentOptions = [
        .alignMinXNearest, .alignMinYNearest, .alignWidthOutward, .alignHeightOutward,
    ]
}

/// The "CURRENT" tag beside the displayed scope: an outlined capsule.
final class CurrentPillView: NSView {
    private static let font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
    private static let horizontalPadding: CGFloat = 5
    private static let height: CGFloat = 16
    private let textSize: NSSize

    override init(frame: NSRect) {
        textSize = Self.attributedText(color: .labelColor).size()
        super.init(frame: frame)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Current")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func attributedText(color: NSColor) -> NSAttributedString {
        NSAttributedString(string: "CURRENT", attributes: [.font: font, .kern: 0.475, .foregroundColor: color])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(textSize.width) + Self.horizontalPadding * 2, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        border.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.26).setStroke()
        border.stroke()
        // The capitals, not the line box, are centred: the baseline sits `ascender`
        // below the line's top.
        let baseline = bounds.midY - Self.font.capHeight / 2
        let origin = NSPoint(
            x: (bounds.width - textSize.width) / 2, y: baseline - textSize.height + Self.font.ascender)
        Self.attributedText(color: .labelColor).draw(at: origin)
    }
}

/// One scope's face, shared by the table's cells and the pinned Working Tree row:
/// gutter labels on the left, the subject, an optional CURRENT pill, and trailing text.
/// The pill and trailing text are centred on the subject's capitals. As a table cell it
/// stays an accessibility cell; a press, or the "Show" action, activates its scope.
final class ScopeRowContentView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ScopeRowContentView")

    /// Set by the table's owner; nil inside the pinned row, which presses as a whole.
    var onActivate: (() -> Void)?

    enum TrailingStyle {
        /// A commit's hash: monospaced, tertiary.
        case hash
        /// The Working Tree's file count: secondary.
        case fileCount
    }

    struct Content {
        var gutterTitle: String?
        var gutterSubtitle: String?
        var subject: String
        var showsPill: Bool
        var trailing: String
        var trailingStyle: TrailingStyle
    }

    private let gutterTitle = CommitPickerMetrics.label(
        font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor, alignment: .right)
    private let gutterSubtitle = CommitPickerMetrics.label(
        font: .systemFont(ofSize: 11), color: .secondaryLabelColor, alignment: .right)
    private let subject = CommitPickerMetrics.label(font: .systemFont(ofSize: 13.5), color: .labelColor)
    private let pill = CurrentPillView(frame: .zero)
    private let trailing = CommitPickerMetrics.label(
        font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: .tertiaryLabelColor, alignment: .right)
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
        for view in [gutterTitle, gutterSubtitle, subject, pill, trailing] { addSubview(view) }
        pill.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Accessibility

    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard onActivate != nil else { return nil }
        return [NSAccessibilityCustomAction(name: "Show") { [weak self] in self?.accessibilityPerformPress() ?? false }]
    }

    func configure(_ content: Content) {
        gutterTitle.stringValue = content.gutterTitle ?? ""
        gutterSubtitle.stringValue = content.gutterSubtitle ?? ""
        subject.stringValue = content.subject
        pill.isHidden = !content.showsPill
        trailing.stringValue = content.trailing
        switch content.trailingStyle {
        case .hash:
            trailing.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            trailing.textColor = .tertiaryLabelColor
        case .fileCount:
            trailing.font = .systemFont(ofSize: 13)
            trailing.textColor = .secondaryLabelColor
        }
        setAccessibilityLabel(content.showsPill ? "\(content.subject), current" : content.subject)
        needsLayout = true
    }

    // The subject is centred in the row; the trailing text and pill are centred on its
    // capitals, measured first so the subject takes what is left.
    override func layout() {
        super.layout()
        layoutGutter()
        let content = CommitPickerMetrics.contentRect(in: bounds)
        let subjectX = content.minX + CommitPickerMetrics.textInset
        let subjectHeight = CommitPickerMetrics.naturalSize(of: subject).height
        subject.frame = NSRect(
            x: subjectX, y: ((bounds.height - subjectHeight) / 2).rounded(), width: 0, height: subjectHeight)
        let centerY = CommitPickerMetrics.capCenterY(of: subject)
        var rightEdge = content.maxX - CommitPickerMetrics.textInset
        if trailing.stringValue.isEmpty {
            trailing.frame = .zero
        } else {
            let size = CommitPickerMetrics.naturalSize(of: trailing)
            trailing.frame = backingAlignedRect(
                NSRect(
                    x: rightEdge - size.width, y: CommitPickerMetrics.y(centering: trailing, on: centerY),
                    width: size.width, height: size.height),
                options: CommitPickerMetrics.pixelAlignment)
            rightEdge = trailing.frame.minX - 8
        }
        if !pill.isHidden {
            let size = pill.intrinsicContentSize
            pill.frame = backingAlignedRect(
                NSRect(x: rightEdge - size.width, y: centerY - size.height / 2, width: size.width, height: size.height),
                options: CommitPickerMetrics.pixelAlignment)
            rightEdge = pill.frame.minX - 8
        }
        subject.frame.size.width = max(rightEdge - subjectX, 0)
    }

    private func layoutGutter() {
        let maxX = CommitPickerMetrics.gutterWidth - CommitPickerMetrics.gutterTrailingInset
        let width = maxX - 4
        let titleHeight = CommitPickerMetrics.naturalSize(of: gutterTitle).height
        let subtitleHeight =
            gutterSubtitle.stringValue.isEmpty ? 0 : CommitPickerMetrics.naturalSize(of: gutterSubtitle).height
        let top = ((bounds.height - titleHeight - subtitleHeight) / 2).rounded()
        gutterTitle.frame = NSRect(x: maxX - width, y: top, width: width, height: titleHeight)
        gutterSubtitle.frame = NSRect(x: maxX - width, y: top + titleHeight, width: width, height: subtitleHeight)
        gutterSubtitle.isHidden = subtitleHeight == 0
    }
}

/// A table row that highlights only its content area, with rounded corners, and
/// never paints a background of its own so the gutter shows through. The highlight
/// is a neutral fill, so the text keeps its colors.
final class CommitPickerTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("CommitPickerTableRowView")

    /// Set by the table's pointer tracking; drawn only while the row is not selected.
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var highlightPath: NSBezierPath {
        NSBezierPath(
            roundedRect: CommitPickerMetrics.contentRect(in: bounds), xRadius: CommitPickerMetrics.cornerRadius,
            yRadius: CommitPickerMetrics.cornerRadius)
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        CommitPickerMetrics.hoverColor.setFill()
        highlightPath.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        CommitPickerMetrics.highlightColor.setFill()
        highlightPath.fill()
    }
}
