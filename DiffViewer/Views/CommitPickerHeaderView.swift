import AppKit

/// The commit picker's header: the displayed scope's title, wrapped in full, over a
/// subtitle. For a commit that is its author and date, then its hash and a copy button; for
/// Working Tree, its change count.
final class CommitPickerHeaderView: PickerHeaderView {
    private let hashAccessory = CommitHashAccessoryView()

    /// After a copy; the picker returns focus to its search field.
    var onCopy: () -> Void {
        get { hashAccessory.copyButton.onCopy }
        set { hashAccessory.copyButton.onCopy = newValue }
    }

    init() {
        super.init(wrapsTitle: true)
        subtitleAccessory = hashAccessory
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: CommitPickerHeaderText) {
        title = text.title
        subtitle = text.detailParts.joined(separator: " · ")
        hashAccessory.configure(text)
    }
}

/// The dot, the short hash and the copy button after the subtitle's text, which never
/// truncate.
private final class CommitHashAccessoryView: NSView {
    private static let hashFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    let copyButton = PickerCopyButton(label: "Copy SHA")
    /// The labels' own padding spaces the dot.
    private let dot = PickerLabel.make(font: PickerMetrics.Header.subtitleFont, color: .secondaryLabelColor)
    private let shaLabel = PickerLabel.make(font: hashFont, color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        dot.stringValue = "·"
        for view in [dot, shaLabel, copyButton] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(_ text: CommitPickerHeaderText) {
        shaLabel.stringValue = text.shortSha ?? ""
        shaLabel.isHidden = text.shortSha == nil
        dot.isHidden = text.shortSha == nil || text.detailParts.isEmpty
        copyButton.isHidden = text.sha == nil
        if let sha = text.sha { copyButton.configure(text: sha) }
        isHidden = shaLabel.isHidden && copyButton.isHidden
        needsLayout = true
    }

    private var shownParts: [(view: NSView, size: NSSize)] {
        var parts: [(NSView, NSSize)] = []
        if !dot.isHidden { parts.append((dot, PickerViewGeometry.naturalSize(of: dot))) }
        if !shaLabel.isHidden { parts.append((shaLabel, PickerViewGeometry.naturalSize(of: shaLabel))) }
        if !copyButton.isHidden { parts.append((copyButton, copyButton.intrinsicContentSize)) }
        return parts
    }

    override var intrinsicContentSize: NSSize {
        let sizes = shownParts.map(\.size)
        return NSSize(width: sizes.map(\.width).reduce(0, +), height: sizes.map(\.height).max() ?? 0)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (view, size) in shownParts {
            view.frame = backingAlignedRect(
                NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                options: PickerViewGeometry.pixelAlignment)
            x += size.width
        }
    }
}
