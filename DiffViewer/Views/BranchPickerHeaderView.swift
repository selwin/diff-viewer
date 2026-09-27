import AppKit

/// The branch picker's header: where HEAD is, with the CURRENT pill when it is on a
/// branch, a detail line for how far that branch is from its upstream and how the fetch
/// went, and a Fetch button with a spinner while a round runs. Pull and Push live on the
/// rows.
final class BranchPickerHeaderView: NSVisualEffectView {
    private static let topPadding: CGFloat = 13
    private static let sidePadding: CGFloat = 16
    private static let bottomPadding: CGFloat = 12
    private static let lineGap: CGFloat = 3
    private static let controlGap: CGFloat = 6

    private let title = CommitPickerMetrics.label(font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
    private let pill = CurrentPillView(frame: .zero)
    private let detail = CommitPickerMetrics.label(font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let hairline = HairlineView(frame: .zero)
    private let fetchSpinner = NSProgressIndicator(frame: .zero)
    private let fetchButton = NSButton(title: "Fetch", target: nil, action: nil)

    var onFetch: () -> Void = {}
    /// The upstream part of the detail line, kept so the fetch text can be redrawn alone.
    private var upstreamDetail = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        material = .headerView
        blendingMode = .withinWindow
        fetchSpinner.style = .spinning
        fetchSpinner.controlSize = .small
        fetchSpinner.isDisplayedWhenStopped = false
        fetchSpinner.sizeToFit()
        fetchButton.controlSize = .small
        fetchButton.bezelStyle = .push
        fetchButton.target = self
        fetchButton.action = #selector(fetchClicked)
        // The search field keeps the keyboard.
        fetchButton.refusesFirstResponder = true
        fetchButton.sizeToFit()
        for view in [title, pill, detail, hairline, fetchSpinner, fetchButton] { addSubview(view) }
        pill.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// `fetch` follows the upstream on the detail line, and its tooltip covers the line.
    func configure(_ text: BranchPickerHeaderText, fetch: BranchPickerFetchText?) {
        title.stringValue = text.title
        pill.isHidden = !text.showsCurrentPill
        upstreamDetail = text.detail
        configureFetch(fetch)
        fetchButton.isEnabled = text.canFetch
        fetchSpinner.isHidden = !text.showsSpinner
        if text.showsSpinner {
            fetchSpinner.startAnimation(nil)
        } else {
            fetchSpinner.stopAnimation(nil)
        }
        needsLayout = true
    }

    /// Redraws only the fetch text. The detail line's frame spans the header whatever it
    /// says, so this needs no layout.
    func configureFetch(_ fetch: BranchPickerFetchText?) {
        detail.stringValue = [upstreamDetail, fetch?.text ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        detail.toolTip = fetch?.tooltip
    }

    @objc private func fetchClicked() {
        onFetch()
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
        let spinnerSize = fetchSpinner.frame.size
        let buttonSize = fetchButton.frame.size
        // Everything on the trailing edge is measured first; the title takes what is left.
        var trailing = maxX - buttonSize.width - Self.controlGap
        let spinnerMaxX = trailing
        if !fetchSpinner.isHidden { trailing -= spinnerSize.width + Self.controlGap }
        let titleWidth = min(titleSize.width, trailing - Self.sidePadding - pillWidth)
        title.frame = NSRect(
            x: Self.sidePadding, y: Self.topPadding, width: max(titleWidth, 0), height: titleSize.height)

        let centerY = CommitPickerMetrics.capCenterY(of: title)
        fetchButton.frame = backingAlignedRect(
            NSRect(
                x: maxX - buttonSize.width, y: centerY - buttonSize.height / 2, width: buttonSize.width,
                height: buttonSize.height),
            options: CommitPickerMetrics.pixelAlignment)
        if !fetchSpinner.isHidden {
            fetchSpinner.frame = NSRect(
                x: spinnerMaxX - spinnerSize.width, y: centerY - spinnerSize.height / 2, width: spinnerSize.width,
                height: spinnerSize.height)
        }

        if !pill.isHidden {
            let pillSize = pill.intrinsicContentSize
            pill.frame = backingAlignedRect(
                NSRect(
                    x: title.frame.maxX + 8, y: centerY - pillSize.height / 2,
                    width: pillSize.width, height: pillSize.height),
                options: CommitPickerMetrics.pixelAlignment)
        }
        detail.frame = NSRect(
            x: Self.sidePadding, y: title.frame.maxY + Self.lineGap, width: maxX - Self.sidePadding,
            height: Self.detailHeight)
        hairline.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}
