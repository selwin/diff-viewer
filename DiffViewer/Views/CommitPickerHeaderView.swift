import AppKit

/// The commit picker's header: the displayed scope's title, wrapped in full, over a
/// detail line that mirrors a row's second line, with the copy button after the shaLabel.
/// It draws no background of its own, so the header and the list share the popover's
/// one surface.
final class CommitPickerHeaderView: NSView {
    private typealias Metrics = PickerMetrics.Header

    private static let hashFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Between the hash and the copy button. The labels' own padding spaces the dot.
    private static let detailGap: CGFloat = 2

    /// After a copy; the picker returns focus to its search field.
    var onCopy: () -> Void {
        get { copyButton.onCopy }
        set { copyButton.onCopy = newValue }
    }

    /// A commit's subject can run long, so the title wraps rather than truncating.
    private let title: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = Metrics.titleFont
        field.textColor = .labelColor
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.isSelectable = false
        return field
    }()
    private let detail = PickerLabel.make(font: Metrics.detailFont, color: .secondaryLabelColor)
    private let dot = PickerLabel.make(font: Metrics.detailFont, color: .secondaryLabelColor)
    private let shaLabel = PickerLabel.make(font: hashFont, color: .secondaryLabelColor)
    private let copyButton = CopyShaButton(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        dot.stringValue = "·"
        for view in [title, detail, dot, shaLabel, copyButton] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(_ text: CommitPickerHeaderText) {
        title.stringValue = text.title
        detail.stringValue = text.detailParts.joined(separator: " · ")
        shaLabel.stringValue = text.shortSha ?? ""
        shaLabel.isHidden = text.shortSha == nil
        dot.isHidden = text.shortSha == nil || text.detailParts.isEmpty
        copyButton.isHidden = text.sha == nil
        if let sha = text.sha { copyButton.configure(sha: sha) }
        needsLayout = true
    }

    /// The wrapped title, the detail line and padding at `width`. The detail line keeps
    /// its height while empty, so a count arriving later does not move the rows.
    func fittingHeight(width: CGFloat) -> CGFloat {
        Metrics.topPadding + titleHeight(width: width) + Metrics.lineGap + Self.detailHeight + Metrics.bottomPadding
    }

    private func titleHeight(width: CGFloat) -> CGFloat {
        let textWidth = max(width - Metrics.sidePadding * 2, 0)
        let bounds = NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)
        return ceil(title.cell?.cellSize(forBounds: bounds).height ?? 0)
    }

    /// The detail line's height for its font, measured once.
    private static let detailHeight: CGFloat = PickerViewGeometry.naturalSize(
        of: PickerLabel.make(font: Metrics.detailFont, color: .labelColor)
    ).height

    override func layout() {
        super.layout()
        let x = Metrics.sidePadding
        let maxX = bounds.width - Metrics.sidePadding
        title.frame = NSRect(
            x: x, y: Metrics.topPadding, width: max(maxX - x, 0), height: titleHeight(width: bounds.width))
        layoutDetail(x: x, y: title.frame.maxY + Metrics.lineGap, maxX: maxX)
    }

    /// The detail text truncates; the hash and copy button after it never do.
    private func layoutDetail(x: CGFloat, y: CGFloat, maxX: CGFloat) {
        let height = Self.detailHeight
        let dotWidth = dot.isHidden ? 0 : PickerViewGeometry.naturalSize(of: dot).width
        let shaWidth = shaLabel.isHidden ? 0 : PickerViewGeometry.naturalSize(of: shaLabel).width
        let copyWidth = copyButton.isHidden ? 0 : Self.detailGap + CopyShaButton.side
        let detailWidth = min(
            PickerViewGeometry.naturalSize(of: detail).width, max(maxX - x - dotWidth - shaWidth - copyWidth, 0))
        detail.frame = NSRect(x: x, y: y, width: detailWidth, height: height)
        var cursor = detail.frame.maxX
        if !dot.isHidden {
            dot.frame = NSRect(x: cursor, y: y, width: dotWidth, height: height)
            cursor = dot.frame.maxX
        }
        guard !shaLabel.isHidden else { return }
        let shaSize = PickerViewGeometry.naturalSize(of: shaLabel)
        shaLabel.frame = backingAlignedRect(
            NSRect(x: cursor, y: y + (height - shaSize.height) / 2, width: shaSize.width, height: shaSize.height),
            options: PickerViewGeometry.pixelAlignment)
        let side = CopyShaButton.side
        copyButton.frame = backingAlignedRect(
            NSRect(x: shaLabel.frame.maxX + Self.detailGap, y: y + (height - side) / 2, width: side, height: side),
            options: PickerViewGeometry.pixelAlignment)
    }
}
