import AppKit

/// A 1pt separator line.
final class HairlineView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// The gutter's background: a quiet fill with a hairline on its right edge, running
/// from the header to the bottom of the popover behind the rows and footer.
final class CommitPickerGutterView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quinarySystemFill.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }
}

/// The popover's header: the displayed scope's title, always with the CURRENT pill, and
/// a detail line mixing text and monospaced segments.
final class CommitPickerHeaderView: NSVisualEffectView {
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(_ text: CommitPickerHeaderText) {
        title.stringValue = text.title
        detail.attributedStringValue = Self.attributedDetail(text.detail)
        needsLayout = true
    }

    private static func attributedDetail(_ segments: [CommitPickerHeaderText.Segment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments {
            let (string, font): (String, NSFont) =
                switch segment {
                case let .text(string): (string, .systemFont(ofSize: 12))
                case let .mono(string): (string, .monospacedSystemFont(ofSize: 12, weight: .regular))
                }
            result.append(
                NSAttributedString(
                    string: string, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return result
    }

    /// Two text lines, padding, and the hairline; constant so the count arriving later
    /// does not move the rows.
    var fittingHeight: CGFloat {
        Self.topPadding + CommitPickerMetrics.naturalSize(of: title).height + Self.lineGap + Self.detailHeight
            + Self.bottomPadding + 1
    }

    /// The detail line's height for its font, measured once: the attributed text's own
    /// height varies with its segments.
    private static let detailHeight: CGFloat = CommitPickerMetrics.naturalSize(
        of: CommitPickerMetrics.label(font: .systemFont(ofSize: 12), color: .labelColor)
    ).height

    override func layout() {
        super.layout()
        let maxX = bounds.width - Self.sidePadding
        let titleSize = CommitPickerMetrics.naturalSize(of: title)
        let titleHeight = titleSize.height
        let pillSize = pill.intrinsicContentSize
        let titleWidth = min(titleSize.width, maxX - Self.sidePadding - 8 - pillSize.width)
        title.frame = NSRect(x: Self.sidePadding, y: Self.topPadding, width: max(titleWidth, 0), height: titleHeight)
        pill.frame = backingAlignedRect(
            NSRect(
                x: title.frame.maxX + 8, y: CommitPickerMetrics.capCenterY(of: title) - pillSize.height / 2,
                width: pillSize.width, height: pillSize.height),
            options: CommitPickerMetrics.pixelAlignment)
        let detailY = title.frame.maxY + Self.lineGap
        detail.frame = NSRect(
            x: Self.sidePadding, y: detailY, width: maxX - Self.sidePadding, height: Self.detailHeight)
        hairline.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}

/// A borderless, link-colored Retry button.
@MainActor
private func makeRetryLink(target: NSView, action: Selector) -> NSButton {
    let button = NSButton(title: "Retry", target: target, action: action)
    button.isBordered = false
    button.attributedTitle = NSAttributedString(
        string: "Retry", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.linkColor])
    button.setButtonType(.momentaryChange)
    return button
}

/// What follows the rows: a spinner while more load, or a failure with Retry.
final class CommitPickerFooterView: NSView {
    var onRetry: () -> Void = {}

    private let spinner = NSProgressIndicator()
    private let label = CommitPickerMetrics.label(font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private lazy var retry = makeRetryLink(target: self, action: #selector(retryClicked))

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [spinner, label, retry] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(_ footer: CommitPickerFooter) {
        switch footer {
        case .none:
            label.stringValue = ""
        case .loading:
            label.stringValue = "Loading…"
        case .failed:
            label.stringValue = "Couldn't load history"
        }
        let loading = footer == .loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !loading
        retry.isHidden = footer != .failed
        needsLayout = true
    }

    @objc private func retryClicked() {
        onRetry()
    }

    override func layout() {
        super.layout()
        let content = CommitPickerMetrics.contentRect(in: bounds)
        var x = content.minX + CommitPickerMetrics.textInset
        func place(_ view: NSView, size: NSSize) {
            view.frame = NSRect(
                x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width,
                height: size.height)
            x = view.frame.maxX + 6
        }
        if !spinner.isHidden { place(spinner, size: NSSize(width: 16, height: 16)) }
        place(label, size: CommitPickerMetrics.naturalSize(of: label))
        if !retry.isHidden { place(retry, size: retry.intrinsicContentSize) }
    }
}

/// What stands in for an empty table: a spinner, "No commits yet", or a failure with Retry.
final class CommitPickerEmptyStateView: NSView {
    var onRetry: () -> Void = {}

    private let spinner = NSProgressIndicator()
    private let label = CommitPickerMetrics.label(
        font: .systemFont(ofSize: 13), color: .secondaryLabelColor, alignment: .center)
    private lazy var retry: NSButton = {
        let button = NSButton(title: "Retry", target: self, action: #selector(retryClicked))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [spinner, label, retry] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Hidden when nil.
    func configure(_ state: CommitPickerEmptyState?) {
        isHidden = state == nil
        switch state {
        case .none: label.stringValue = ""
        case .loading: label.stringValue = "Loading…"
        case .noCommits: label.stringValue = "No commits yet"
        case .failed: label.stringValue = "Couldn't load history"
        }
        let loading = state == .loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !loading
        retry.isHidden = state != .failed
        needsLayout = true
    }

    @objc private func retryClicked() {
        onRetry()
    }

    override func layout() {
        super.layout()
        let labelSize = CommitPickerMetrics.naturalSize(of: label)
        let spinnerWidth: CGFloat = spinner.isHidden ? 0 : 16 + 6
        let retrySize = retry.isHidden ? .zero : retry.intrinsicContentSize
        let blockHeight = labelSize.height + (retry.isHidden ? 0 : 8 + retrySize.height)
        let top = ((bounds.height - blockHeight) / 2).rounded()
        let lineWidth = spinnerWidth + labelSize.width
        let lineX = ((bounds.width - lineWidth) / 2).rounded()
        if !spinner.isHidden {
            spinner.frame = NSRect(x: lineX, y: top + ((labelSize.height - 16) / 2).rounded(), width: 16, height: 16)
        }
        label.frame = NSRect(x: lineX + spinnerWidth, y: top, width: labelSize.width, height: labelSize.height)
        if !retry.isHidden {
            retry.frame = NSRect(
                x: ((bounds.width - retrySize.width) / 2).rounded(), y: label.frame.maxY + 8, width: retrySize.width,
                height: retrySize.height)
        }
    }
}
