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
    static let footerHeight: CGFloat = 30

    static func contentRect(in bounds: NSRect) -> NSRect {
        NSRect(
            x: contentLeading, y: bounds.minY, width: bounds.width - contentLeading - contentTrailing,
            height: bounds.height)
    }

    /// The highlighted row's fill: neutral, and clearly stronger than the hover fill
    /// and the pinned row's resting fill (both quaternary).
    static let highlightColor = NSColor.secondarySystemFill
    static let hoverColor = NSColor.quaternarySystemFill
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

/// One row's face, shared by the commit picker's cells and pinned Working Tree row:
/// gutter labels on the left, the subject, an optional CURRENT pill, trailing text, and
/// an optional accessory.
/// The pill, trailing text and accessory are centred on the subject's capitals. As a
/// table cell it stays an accessibility cell; a press, or the named accessibility action,
/// activates the row, and the accessory's own actions are offered beside it.
final class ScopeRowContentView: NSTableCellView, PickerRowAccessoryHosting {
    static let identifier = NSUserInterfaceItemIdentifier("ScopeRowContentView")

    /// Set by the table's owner; nil inside the pinned row, which presses as a whole,
    /// and on rows that cannot be activated.
    var onActivate: (() -> Void)?

    /// A view at the right edge, before the trailing text; the commit picker never sets
    /// one. Takes the space it needs only while it shows.
    var accessory: NSView? {
        didSet {
            guard accessory !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let accessory { addSubview(accessory) }
            needsLayout = true
        }
    }

    enum TrailingStyle {
        /// A commit's hash: monospaced, tertiary.
        case hash
        /// Plain words beside the subject, such as a file count: secondary.
        case secondary
    }

    struct Content {
        var gutterTitle: String?
        var gutterSubtitle: String?
        var subject: String
        var showsCurrentPill: Bool
        var trailing: String
        var trailingStyle: TrailingStyle
        /// The accessibility action's name: what activating this row does.
        var accessibilityActionName: String
    }

    private static let subjectFont = NSFont.systemFont(ofSize: 13.5)

    private let gutterTitle = PickerLabel.make(
        font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor, alignment: .right)
    private let gutterSubtitle = PickerLabel.make(
        font: .systemFont(ofSize: 11), color: .secondaryLabelColor, alignment: .right)
    private let subject = PickerLabel.make(font: subjectFont, color: .labelColor)
    private let pill = CurrentPillView(frame: .zero)
    private var accessibilityActionName = "Show"
    private let trailing = PickerLabel.make(
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
        var actions: [NSAccessibilityCustomAction] = []
        if onActivate != nil {
            actions.append(
                NSAccessibilityCustomAction(name: accessibilityActionName) { [weak self] in
                    self?.accessibilityPerformPress() ?? false
                })
        }
        actions += accessory?.accessibilityCustomActions() ?? []
        return actions.isEmpty ? nil : actions
    }

    func configure(_ content: Content) {
        gutterTitle.stringValue = content.gutterTitle ?? ""
        gutterSubtitle.stringValue = content.gutterSubtitle ?? ""
        subject.stringValue = content.subject
        pill.isHidden = !content.showsCurrentPill
        trailing.stringValue = content.trailing
        accessibilityActionName = content.accessibilityActionName
        switch content.trailingStyle {
        case .hash:
            trailing.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            trailing.textColor = .tertiaryLabelColor
        case .secondary:
            trailing.font = .systemFont(ofSize: 13)
            trailing.textColor = .secondaryLabelColor
        }
        setAccessibilityLabel(content.showsCurrentPill ? "\(content.subject), current" : content.subject)
        needsLayout = true
    }

    // The subject is centred in the row; the trailing text and pill are centred on its
    // capitals, measured first so the subject takes what is left.
    override func layout() {
        super.layout()
        layoutGutter()
        let content = CommitPickerMetrics.contentRect(in: bounds)
        let subjectX = content.minX + CommitPickerMetrics.textInset
        let subjectHeight = PickerViewGeometry.naturalSize(of: subject).height
        subject.frame = NSRect(
            x: subjectX, y: ((bounds.height - subjectHeight) / 2).rounded(), width: 0, height: subjectHeight)
        let centerY = PickerViewGeometry.capCenterY(of: subject)
        var rightEdge = content.maxX - CommitPickerMetrics.textInset
        if let accessory, !accessory.isHidden {
            let size = accessory.intrinsicContentSize
            accessory.frame = backingAlignedRect(
                NSRect(x: rightEdge - size.width, y: centerY - size.height / 2, width: size.width, height: size.height),
                options: PickerViewGeometry.pixelAlignment)
            rightEdge = accessory.frame.minX - 8
        }
        if trailing.stringValue.isEmpty {
            trailing.frame = .zero
        } else {
            let size = PickerViewGeometry.naturalSize(of: trailing)
            trailing.frame = backingAlignedRect(
                NSRect(
                    x: rightEdge - size.width, y: PickerViewGeometry.y(centering: trailing, on: centerY),
                    width: size.width, height: size.height),
                options: PickerViewGeometry.pixelAlignment)
            rightEdge = trailing.frame.minX - 8
        }
        if !pill.isHidden {
            let size = pill.intrinsicContentSize
            pill.frame = backingAlignedRect(
                NSRect(x: rightEdge - size.width, y: centerY - size.height / 2, width: size.width, height: size.height),
                options: PickerViewGeometry.pixelAlignment)
            rightEdge = pill.frame.minX - 8
        }
        subject.frame.size.width = max(rightEdge - subjectX, 0)
    }

    private func layoutGutter() {
        let maxX = CommitPickerMetrics.gutterWidth - CommitPickerMetrics.gutterTrailingInset
        let width = maxX - 4
        let titleHeight = PickerViewGeometry.naturalSize(of: gutterTitle).height
        let subtitleHeight =
            gutterSubtitle.stringValue.isEmpty ? 0 : PickerViewGeometry.naturalSize(of: gutterSubtitle).height
        let top = ((bounds.height - titleHeight - subtitleHeight) / 2).rounded()
        gutterTitle.frame = NSRect(x: maxX - width, y: top, width: width, height: titleHeight)
        gutterSubtitle.frame = NSRect(x: maxX - width, y: top + titleHeight, width: width, height: subtitleHeight)
        gutterSubtitle.isHidden = subtitleHeight == 0
    }
}
