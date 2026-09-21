import AppKit

/// The branch picker's header: where HEAD is, with the CURRENT pill when it is on a
/// branch, and a detail line for how far that branch is from its upstream.
final class BranchPickerHeaderView: NSVisualEffectView {
    private static let topPadding: CGFloat = 13
    private static let sidePadding: CGFloat = 16
    private static let bottomPadding: CGFloat = 12
    private static let lineGap: CGFloat = 3

    private let title = CommitPickerMetrics.label(font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
    private let pill = CurrentPillView(frame: .zero)
    private let detail = CommitPickerMetrics.label(font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let hairline = HairlineView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        material = .headerView
        blendingMode = .withinWindow
        for view in [title, pill, detail, hairline] { addSubview(view) }
        pill.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(_ text: BranchPickerHeaderText) {
        title.stringValue = text.title
        pill.isHidden = !text.showsCurrentPill
        detail.stringValue = text.detail
        needsLayout = true
    }

    /// Two text lines, padding, and the hairline; constant so counts arriving later do
    /// not move the rows.
    var fittingHeight: CGFloat {
        Self.topPadding + CommitPickerMetrics.naturalSize(of: title).height + Self.lineGap + Self.detailHeight
            + Self.bottomPadding + 1
    }

    /// The detail line's height for its font, measured once, so an empty line still
    /// reserves its space.
    private static let detailHeight: CGFloat = CommitPickerMetrics.naturalSize(
        of: CommitPickerMetrics.label(font: .systemFont(ofSize: 12), color: .labelColor)
    ).height

    override func layout() {
        super.layout()
        let maxX = bounds.width - Self.sidePadding
        let titleSize = CommitPickerMetrics.naturalSize(of: title)
        let pillWidth = pill.isHidden ? 0 : pill.intrinsicContentSize.width + 8
        // Laid out against `maxX` rather than the text's own width, so buttons added on
        // the trailing edge later only have to shrink it.
        let titleWidth = min(titleSize.width, maxX - Self.sidePadding - pillWidth)
        title.frame = NSRect(
            x: Self.sidePadding, y: Self.topPadding, width: max(titleWidth, 0), height: titleSize.height)
        if !pill.isHidden {
            let pillSize = pill.intrinsicContentSize
            pill.frame = backingAlignedRect(
                NSRect(
                    x: title.frame.maxX + 8, y: CommitPickerMetrics.capCenterY(of: title) - pillSize.height / 2,
                    width: pillSize.width, height: pillSize.height),
                options: CommitPickerMetrics.pixelAlignment)
        }
        detail.frame = NSRect(
            x: Self.sidePadding, y: title.frame.maxY + Self.lineGap, width: maxX - Self.sidePadding,
            height: Self.detailHeight)
        hairline.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}
