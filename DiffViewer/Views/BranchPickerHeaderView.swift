import AppKit

/// The branch picker's header: where HEAD is, with the CURRENT pill when it is on a
/// branch, a detail line for how far that branch is from its upstream, and the Pull and
/// Push buttons for closing that gap.
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
    private let pullButton = NSButton(title: "Pull", target: nil, action: nil)
    private let pushButton = NSButton(title: "Push", target: nil, action: nil)
    private let pullSpinner = NSProgressIndicator(frame: .zero)
    private let pushSpinner = NSProgressIndicator(frame: .zero)
    /// Measured once with the title in place, so a running button keeps its width while
    /// its title is blank.
    private var pullSize = NSSize.zero
    private var pushSize = NSSize.zero

    var onPull: () -> Void = {}
    var onPush: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        material = .headerView
        blendingMode = .withinWindow
        configure(fetchSpinner)
        for (button, indicator) in [(pullButton, pullSpinner), (pushButton, pushSpinner)] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.sizeToFit()
            // No key equivalent is set: Return belongs to the highlighted branch row.
            configure(indicator)
            indicator.frame.size = NSSize(width: 16, height: 16)
            button.addSubview(indicator)
        }
        pullSize = pullButton.frame.size
        pushSize = pushButton.frame.size
        pullButton.bezelColor = .controlAccentColor
        pullButton.target = self
        pullButton.action = #selector(pullClicked)
        pushButton.target = self
        pushButton.action = #selector(pushClicked)
        for view in [title, pill, detail, hairline, fetchSpinner, pushButton, pullButton] { addSubview(view) }
        pill.isHidden = true
    }

    private func configure(_ indicator: NSProgressIndicator) {
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        indicator.sizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func pullClicked() { onPull() }
    @objc private func pushClicked() { onPush() }

    func configure(
        _ text: BranchPickerHeaderText, pull pullState: PickerButtonState, push pushState: PickerButtonState
    ) {
        title.stringValue = text.title
        pill.isHidden = !text.showsCurrentPill
        detail.stringValue = text.detail
        fetchSpinner.isHidden = !text.showsSpinner
        if text.showsSpinner {
            fetchSpinner.startAnimation(nil)
        } else {
            fetchSpinner.stopAnimation(nil)
        }
        apply(pullState, to: pullButton, indicator: pullSpinner, title: "Pull")
        apply(pushState, to: pushButton, indicator: pushSpinner, title: "Push")
        needsLayout = true
    }

    /// A running button keeps its place and its width, and says so to VoiceOver: the
    /// spinner replaces the title rather than the button.
    private func apply(
        _ state: PickerButtonState, to button: NSButton, indicator: NSProgressIndicator, title: String
    ) {
        button.isHidden = state == .hidden
        button.title = state == .running ? "" : title
        button.isEnabled = state == .enabled
        button.toolTip = if case let .disabled(reason) = state { reason } else { nil }
        button.setAccessibilityLabel(state == .running ? "\(title), in progress" : title)
        if state == .running {
            indicator.startAnimation(nil)
        } else {
            indicator.stopAnimation(nil)
        }
        indicator.isHidden = state != .running
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
        // Everything on the trailing edge is measured first; the title takes what is left.
        var trailing = maxX
        if !fetchSpinner.isHidden { trailing -= spinnerSize.width + Self.controlGap }
        if !pullButton.isHidden { trailing -= pullSize.width + Self.controlGap }
        if !pushButton.isHidden { trailing -= pushSize.width + Self.controlGap }
        let titleWidth = min(titleSize.width, trailing - Self.sidePadding - pillWidth)
        title.frame = NSRect(
            x: Self.sidePadding, y: Self.topPadding, width: max(titleWidth, 0), height: titleSize.height)

        let centerY = CommitPickerMetrics.capCenterY(of: title)
        var x = maxX
        if !fetchSpinner.isHidden {
            x -= spinnerSize.width
            fetchSpinner.frame = NSRect(
                x: x, y: centerY - spinnerSize.height / 2, width: spinnerSize.width, height: spinnerSize.height)
            x -= Self.controlGap
        }
        // Pull sits closest to the fetch spinner, Push to its left, so the two keep their order
        // whichever of them is showing.
        for (button, size) in [(pullButton, pullSize), (pushButton, pushSize)] where !button.isHidden {
            x -= size.width
            button.frame = NSRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
            x -= Self.controlGap
        }
        for (button, indicator) in [(pullButton, pullSpinner), (pushButton, pushSpinner)] where !indicator.isHidden {
            indicator.frame = NSRect(
                x: (button.bounds.width - indicator.frame.width) / 2,
                y: (button.bounds.height - indicator.frame.height) / 2,
                width: indicator.frame.width, height: indicator.frame.height)
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
