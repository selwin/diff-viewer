import AppKit

/// A commit row: the subject and hash over the author and, if unpushed, `Not pushed`.
/// Working Tree's row is one line with its change count. The displayed scope's row ends
/// in a checkmark; the highlighted row shows a copy button before the hash. A press, or
/// the named accessibility action, activates the row.
final class CommitPickerRowView: NSTableCellView, PickerRowAccessoryHosting {
    static let identifier = NSUserInterfaceItemIdentifier("CommitPickerRowView")
    /// Working Tree's row, which has no second line.
    static let singleLineHeight: CGFloat = 32

    private static let hashFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let checkmarkSize: CGFloat = 14

    /// Set by the table's owner.
    var onActivate: (() -> Void)?

    /// On the accent fill every part turns white, and the copy button shows.
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { applyHighlight() } }
    }

    let copyButton = PickerCopyButton(label: "Copy SHA")

    /// The copy button, on a commit row: the table sends clicks on it to the button, never
    /// to the row.
    var accessories: [NSView] {
        sha == nil ? [] : [copyButton]
    }

    private let name = PickerLabel.make(font: PickerMetrics.nameFont, color: .labelColor)
    /// The hash on a commit row, the change count on Working Tree's.
    private let trailingLabel = PickerLabel.make(font: hashFont, color: .secondaryLabelColor, alignment: .right)
    private let subtitle = PickerLabel.make(font: PickerMetrics.subtitleFont, color: .secondaryLabelColor)
    private let status = PickerLabel.make(
        font: PickerMetrics.subtitleFont, color: .secondaryLabelColor, alignment: .right)
    private let checkmark = NSImageView()
    private var sha: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        checkmark.imageScaling = .scaleNone
        for view in [name, trailingLabel, subtitle, copyButton, status, checkmark] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(_ row: CommitPickerRow) {
        sha = row.sha
        name.stringValue = row.subject
        trailingLabel.stringValue = row.shortSha
        trailingLabel.font = Self.hashFont
        subtitle.stringValue = row.authorName
        status.stringValue = row.status.text
        copyButton.configure(text: row.sha)
        finishConfigure(
            isSelectedScope: row.isSelectedScope,
            described: [row.subject, row.authorName, row.shortSha, row.status.text])
    }

    func configure(_ row: CommitPickerWorkingTreeRow) {
        sha = nil
        name.stringValue = CommitPickerWorkingTreeRow.title
        trailingLabel.stringValue = row.detail ?? ""
        trailingLabel.font = PickerMetrics.statusFont
        subtitle.stringValue = ""
        status.stringValue = ""
        finishConfigure(
            isSelectedScope: row.isSelectedScope, described: [CommitPickerWorkingTreeRow.title, row.detail ?? ""])
    }

    private func finishConfigure(isSelectedScope: Bool, described: [String]) {
        name.font = isSelectedScope ? PickerMetrics.currentNameFont : PickerMetrics.nameFont
        checkmark.isHidden = !isSelectedScope
        var parts = described
        if isSelectedScope { parts.insert("current", at: 1) }
        setAccessibilityLabel(parts.filter { !$0.isEmpty }.joined(separator: ", "))
        applyHighlight()
        needsLayout = true
    }

    private func applyHighlight() {
        let primary: NSColor = isHighlighted ? .white : .labelColor
        let secondary: NSColor = isHighlighted ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        name.textColor = primary
        for label in [trailingLabel, subtitle, status] { label.textColor = secondary }
        checkmark.contentTintColor = isHighlighted ? .white : .controlAccentColor
        copyButton.isOnAccent = isHighlighted
        copyButton.isHidden = sha == nil || !isHighlighted
    }

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
                NSAccessibilityCustomAction(name: "Show") { [weak self] in
                    self?.accessibilityPerformPress() ?? false
                })
        }
        if sha != nil {
            actions.append(
                NSAccessibilityCustomAction(name: "Copy SHA") { [weak self] in
                    guard let self else { return false }
                    copyButton.copyText()
                    return true
                })
        }
        return actions.isEmpty ? nil : actions
    }

    // MARK: Layout

    // The checkmark is centred on the row. The text lines are centred as a block and end
    // before the checkmark.
    override func layout() {
        super.layout()
        let leading = PickerMetrics.rowInset + PickerMetrics.contentInset
        var rightEdge = bounds.width - leading
        if !checkmark.isHidden {
            checkmark.frame = NSRect(
                x: rightEdge - Self.checkmarkSize, y: ((bounds.height - Self.checkmarkSize) / 2).rounded(),
                width: Self.checkmarkSize, height: Self.checkmarkSize)
            rightEdge = checkmark.frame.minX - PickerMetrics.trailingGap
        }

        let nameHeight = PickerViewGeometry.naturalSize(of: name).height
        let hasSecondLine = !subtitle.stringValue.isEmpty || !status.stringValue.isEmpty
        let secondLineHeight = hasSecondLine ? PickerViewGeometry.naturalSize(of: subtitle).height : 0
        let blockHeight = nameHeight + (hasSecondLine ? PickerMetrics.lineGap + secondLineHeight : 0)
        let top = ((bounds.height - blockHeight) / 2).rounded()
        layoutLine(
            leading: name, trailing: trailingLabel,
            in: NSRect(x: leading, y: top, width: rightEdge - leading, height: nameHeight),
            reserve: sha == nil ? 0 : PickerCopyButton.side)
        layoutCopyButton()
        subtitle.isHidden = !hasSecondLine
        status.isHidden = !hasSecondLine
        guard hasSecondLine else { return }
        layoutLine(
            leading: subtitle, trailing: status,
            in: NSRect(
                x: leading, y: name.frame.maxY + PickerMetrics.lineGap, width: rightEdge - leading,
                height: secondLineHeight),
            reserve: 0)
    }

    /// Puts `trailing` flush right in `line`; `leading` gets the rest, less `reserve`, and
    /// truncates.
    private func layoutLine(leading: NSTextField, trailing: NSTextField, in line: NSRect, reserve: CGFloat) {
        var textMaxX = line.maxX
        if trailing.stringValue.isEmpty {
            trailing.frame = .zero
        } else {
            let size = PickerViewGeometry.naturalSize(of: trailing)
            trailing.frame = backingAlignedRect(
                NSRect(
                    x: line.maxX - size.width, y: line.midY - size.height / 2, width: size.width,
                    height: size.height),
                options: PickerViewGeometry.pixelAlignment)
            textMaxX = trailing.frame.minX - reserve - PickerMetrics.trailingGap
        }
        leading.frame = NSRect(x: line.minX, y: line.minY, width: max(textMaxX - line.minX, 0), height: line.height)
    }

    /// Against the hash, since its hover fill already pads the icon. `layout` keeps its room
    /// while it is hidden, so the subject does not re-truncate as the highlight moves.
    private func layoutCopyButton() {
        guard sha != nil else { return }
        let side = PickerCopyButton.side
        copyButton.frame = backingAlignedRect(
            NSRect(x: trailingLabel.frame.minX - side, y: name.frame.midY - side / 2, width: side, height: side),
            options: PickerViewGeometry.pixelAlignment)
        // A reused cell's button may have moved out from under the pointer.
        copyButton.refreshHover(animated: false)
    }
}
