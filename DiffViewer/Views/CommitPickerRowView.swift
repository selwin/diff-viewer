import AppKit

/// A scope row: the subject over `author · date · hash`, then `Not pushed` and, on the
/// displayed scope's row, a checkmark at the right. The copy button follows the hash on
/// the highlighted row only. Working Tree uses the same row, with its change count as the
/// second line and no shaLabel. As a table cell it stays an accessibility cell; a press, or
/// the named accessibility action, activates the row.
final class CommitPickerRowView: NSTableCellView, PickerRowAccessoryHosting {
    static let identifier = NSUserInterfaceItemIdentifier("CommitPickerRowView")

    private static let hashFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    /// Between the hash and the copy button, whose hover fill already pads the icon. The
    /// labels' own padding spaces the dot.
    private static let detailGap: CGFloat = 0
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
    private let subtitle = PickerLabel.make(font: PickerMetrics.subtitleFont, color: .secondaryLabelColor)
    private let dot = PickerLabel.make(font: PickerMetrics.subtitleFont, color: .secondaryLabelColor)
    private let shaLabel = PickerLabel.make(font: hashFont, color: .secondaryLabelColor)
    private let status = PickerLabel.make(
        font: PickerMetrics.statusFont, color: .secondaryLabelColor, alignment: .right)
    private let checkmark = NSImageView()
    private var sha: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
        dot.stringValue = "·"
        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        checkmark.imageScaling = .scaleNone
        for view in [name, subtitle, dot, shaLabel, copyButton, status, checkmark] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// What a row shows; `sha` and `shortSha` are nil for Working Tree.
    private struct Face {
        var title: String
        var detail: String
        var shortSha: String?
        var sha: String?
        var status: String
        var isSelectedScope: Bool
    }

    func configure(_ row: CommitPickerRow) {
        configure(
            Face(
                title: row.subject, detail: "\(row.authorName) · \(row.dateText)", shortSha: row.shortSha,
                sha: row.sha, status: row.status.text, isSelectedScope: row.isSelectedScope))
    }

    func configure(_ row: CommitPickerWorkingTreeRow) {
        configure(
            Face(
                title: CommitPickerWorkingTreeRow.title, detail: row.detail ?? "", status: "",
                isSelectedScope: row.isSelectedScope))
    }

    private func configure(_ face: Face) {
        sha = face.sha
        name.stringValue = face.title
        name.font = face.isSelectedScope ? PickerMetrics.currentNameFont : PickerMetrics.nameFont
        subtitle.stringValue = face.detail
        shaLabel.stringValue = face.shortSha ?? ""
        dot.isHidden = face.shortSha == nil || face.detail.isEmpty
        shaLabel.isHidden = face.shortSha == nil
        if let sha = face.sha { copyButton.configure(text: sha) }
        status.stringValue = face.status
        checkmark.isHidden = !face.isSelectedScope
        let described = [
            face.title, face.isSelectedScope ? "current" : "", face.detail, face.shortSha ?? "", face.status,
        ]
        setAccessibilityLabel(described.filter { !$0.isEmpty }.joined(separator: ", "))
        applyHighlight()
        needsLayout = true
    }

    private func applyHighlight() {
        let primary: NSColor = isHighlighted ? .white : .labelColor
        let secondary: NSColor = isHighlighted ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        name.textColor = primary
        for label in [subtitle, dot, shaLabel, status] { label.textColor = secondary }
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

    // The status and checkmark are centred on the row, measured first so the text takes
    // what is left. The two text lines are centred as a block; a lone subject is centred.
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
        if status.stringValue.isEmpty {
            status.frame = .zero
        } else {
            let size = PickerViewGeometry.naturalSize(of: status)
            status.frame = backingAlignedRect(
                NSRect(
                    x: rightEdge - size.width, y: (bounds.height - size.height) / 2, width: size.width,
                    height: size.height),
                options: PickerViewGeometry.pixelAlignment)
            rightEdge = status.frame.minX - PickerMetrics.trailingGap
        }

        let textWidth = max(rightEdge - leading, 0)
        let nameHeight = PickerViewGeometry.naturalSize(of: name).height
        let hasDetail = !subtitle.stringValue.isEmpty || !shaLabel.isHidden
        let detailHeight = hasDetail ? PickerViewGeometry.naturalSize(of: subtitle).height : 0
        let blockHeight = nameHeight + (hasDetail ? PickerMetrics.lineGap + detailHeight : 0)
        let top = ((bounds.height - blockHeight) / 2).rounded()
        name.frame = NSRect(x: leading, y: top, width: textWidth, height: nameHeight)
        layoutDetail(x: leading, y: name.frame.maxY + PickerMetrics.lineGap, maxX: rightEdge, height: detailHeight)
    }

    /// `author · date`, truncating, then the hash and copy button, which never do. The
    /// copy button's room is kept while it is hidden, so the line does not shift as the
    /// highlight moves.
    private func layoutDetail(x: CGFloat, y: CGFloat, maxX: CGFloat, height: CGFloat) {
        var tail: CGFloat = 0
        if !shaLabel.isHidden {
            tail += PickerViewGeometry.naturalSize(of: shaLabel).width + Self.detailGap + PickerCopyButton.side
            if !dot.isHidden { tail += PickerViewGeometry.naturalSize(of: dot).width }
        }
        let subtitleWidth = min(PickerViewGeometry.naturalSize(of: subtitle).width, max(maxX - x - tail, 0))
        subtitle.frame = NSRect(x: x, y: y, width: subtitleWidth, height: height)
        var cursor = subtitle.frame.maxX
        if !dot.isHidden {
            let width = PickerViewGeometry.naturalSize(of: dot).width
            dot.frame = NSRect(x: cursor, y: y, width: width, height: height)
            cursor = dot.frame.maxX
        }
        guard !shaLabel.isHidden else { return }
        let shaSize = PickerViewGeometry.naturalSize(of: shaLabel)
        shaLabel.frame = backingAlignedRect(
            NSRect(x: cursor, y: y + (height - shaSize.height) / 2, width: shaSize.width, height: shaSize.height),
            options: PickerViewGeometry.pixelAlignment)
        let side = PickerCopyButton.side
        copyButton.frame = backingAlignedRect(
            NSRect(x: shaLabel.frame.maxX + Self.detailGap, y: y + (height - side) / 2, width: side, height: side),
            options: PickerViewGeometry.pixelAlignment)
        // A reused cell's button may have moved out from under the pointer.
        copyButton.refreshHover(animated: false)
    }
}
