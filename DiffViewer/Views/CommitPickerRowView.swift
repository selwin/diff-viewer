import AppKit

/// A commit row: a round icon tile, the subject and short hash over `author · time` and, if
/// unpushed, `Not pushed`. Working Tree's row is one line with its change count. The
/// displayed scope's tile is the accent checkmark; the highlighted row shows a copy button
/// before the hash. A press, or the named accessibility action, activates the row.
final class CommitPickerRowView: NSTableCellView, PickerRowAccessoryHosting {
    static let identifier = NSUserInterfaceItemIdentifier("CommitPickerRowView")

    private static let hashFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let tileGap: CGFloat = 12
    private static let lineGap: CGFloat = 1
    /// Kept before the hash for the copy button even while it is hidden, so the subject
    /// does not re-truncate as the highlight moves.
    private static let copyRoom: CGFloat = 18
    private static let commitGlyph = PickerRowIconTile.Glyph(
        image: .asset(.gitCommit, side: 14), tint: .secondaryLabelColor, fill: PickerStyle.tileFill)
    private static let workingTreeGlyph = PickerRowIconTile.Glyph(
        image: .symbol("square.and.pencil", pointSize: 13, weight: .medium), tint: .secondaryLabelColor,
        fill: PickerStyle.tileFill)

    /// Set by the table's owner.
    var onActivate: (() -> Void)?

    /// Shows the copy button.
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { updateCopyButton() } }
    }

    let copyButton = PickerCopyButton(label: "Copy SHA")

    /// The copy button, on a commit row: the table sends clicks on it to the button, never
    /// to the row.
    var accessories: [NSView] {
        sha == nil ? [] : [copyButton]
    }

    private let tile = PickerRowIconTile(frame: .zero)
    private let name = PickerLabel.make(font: PickerStyle.nameFont, color: .labelColor)
    private let hashLabel = PickerLabel.make(font: hashFont, color: PickerStyle.meta, alignment: .right)
    private let author = PickerLabel.make(font: PickerStyle.metaFont, color: PickerStyle.meta)
    private let time = PickerLabel.make(font: PickerStyle.metaFont, color: PickerStyle.meta)
    /// `Not pushed` on a commit row, the change count on Working Tree's.
    private let detail = PickerLabel.make(font: PickerStyle.rowStatusFont, color: PickerStyle.meta, alignment: .right)
    private var sha: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
        for view in [tile, name, hashLabel, copyButton, author, time, detail] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(_ row: CommitPickerRow) {
        sha = row.sha
        tile.configure(row.isSelectedScope ? .current : Self.commitGlyph)
        name.stringValue = row.subject
        hashLabel.stringValue = row.shortSha
        author.stringValue = row.authorName
        // The labels' own padding spaces the dot.
        time.stringValue = row.authorName.isEmpty ? row.timeText : "· \(row.timeText)"
        detail.stringValue = row.status.text
        copyButton.configure(text: row.sha)
        finishConfigure(
            isSelectedScope: row.isSelectedScope,
            described: [row.subject, row.authorName, row.timeText, row.shortSha, row.status.text])
    }

    func configure(_ row: CommitPickerWorkingTreeRow) {
        sha = nil
        tile.configure(row.isSelectedScope ? .current : Self.workingTreeGlyph)
        name.stringValue = CommitPickerWorkingTreeRow.title
        detail.stringValue = row.detail ?? ""
        finishConfigure(
            isSelectedScope: row.isSelectedScope, described: [CommitPickerWorkingTreeRow.title, row.detail ?? ""])
    }

    private func finishConfigure(isSelectedScope: Bool, described: [String]) {
        for label in [hashLabel, author, time] { label.isHidden = sha == nil }
        var parts = described
        if isSelectedScope { parts.insert("current", at: 1) }
        setAccessibilityLabel(parts.filter { !$0.isEmpty }.joined(separator: ", "))
        updateCopyButton()
        needsLayout = true
    }

    private func updateCopyButton() {
        copyButton.isHidden = sha == nil || !isHighlighted
    }

    /// Redraws the tile with the current accessibility display options.
    func refreshRendering() {
        tile.needsDisplay = true
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

    /// Where the text starts, past the tile.
    private static let textX =
        PickerStyle.highlightInset + PickerStyle.contentInset + PickerStyle.iconTileSize + tileGap

    private var contentMaxX: CGFloat { bounds.width - PickerStyle.highlightInset - PickerStyle.contentInset }

    // The tile is centred on the row, and so is the text: one line, or two as a block.
    override func layout() {
        super.layout()
        let side = PickerStyle.iconTileSize
        tile.frame = NSRect(
            x: PickerStyle.highlightInset + PickerStyle.contentInset, y: ((bounds.height - side) / 2).rounded(),
            width: side, height: side)
        if sha == nil { layoutWorkingTree() } else { layoutCommit() }
    }

    /// The title, then the change count flush right; the title truncates first.
    private func layoutWorkingTree() {
        let nameHeight = PickerViewGeometry.naturalSize(of: name).height
        let y = ((bounds.height - nameHeight) / 2).rounded()
        let nameMaxX =
            placeFlushRight(detail, onBaselineOf: name, lineY: y, lineHeight: nameHeight).map {
                $0 - PickerStyle.trailingGap
            } ?? contentMaxX
        name.frame = NSRect(x: Self.textX, y: y, width: max(nameMaxX - Self.textX, 0), height: nameHeight)
    }

    /// Each line is laid out right to left. The subject's: the hash, the copy button's room,
    /// then the subject, truncating. The second: `Not pushed`, `· time` at its natural
    /// width, then the author, truncating.
    private func layoutCommit() {
        let nameHeight = PickerViewGeometry.naturalSize(of: name).height
        let metaHeight = PickerViewGeometry.naturalSize(of: author).height
        let top = ((bounds.height - nameHeight - Self.lineGap - metaHeight) / 2).rounded()

        let hashMinX = placeFlushRight(hashLabel, onBaselineOf: name, lineY: top, lineHeight: nameHeight) ?? contentMaxX
        name.frame = NSRect(
            x: Self.textX, y: top, width: max(hashMinX - Self.copyRoom - Self.textX, 0), height: nameHeight)
        layoutCopyButton()

        let metaY = name.frame.maxY + Self.lineGap
        let metaMaxX =
            placeFlushRight(detail, onBaselineOf: author, lineY: metaY, lineHeight: metaHeight).map {
                $0 - PickerStyle.trailingGap
            } ?? contentMaxX
        let available = max(metaMaxX - Self.textX, 0)
        let timeWidth = min(PickerViewGeometry.naturalSize(of: time).width, available)
        let authorWidth =
            author.stringValue.isEmpty
            ? 0 : min(PickerViewGeometry.naturalSize(of: author).width, available - timeWidth)
        author.frame = NSRect(x: Self.textX, y: metaY, width: authorWidth, height: metaHeight)
        time.frame = backingAlignedRect(
            NSRect(x: author.frame.maxX, y: metaY, width: timeWidth, height: metaHeight),
            options: PickerViewGeometry.pixelAlignment)
    }

    /// Puts `label` at its natural width against the content's trailing edge, on the
    /// baseline of the line `reference` will take at `lineY`. Returns the label's start, or
    /// nil when it is empty.
    private func placeFlushRight(
        _ label: NSTextField, onBaselineOf reference: NSTextField, lineY: CGFloat, lineHeight: CGFloat
    ) -> CGFloat? {
        guard !label.stringValue.isEmpty else {
            label.frame = .zero
            return nil
        }
        let size = PickerViewGeometry.naturalSize(of: label)
        // Baselines are read from frames at their final heights.
        reference.frame = NSRect(x: Self.textX, y: lineY, width: reference.frame.width, height: lineHeight)
        label.frame.size = size
        let y = lineY + reference.firstBaselineOffsetFromTop - label.firstBaselineOffsetFromTop
        label.frame = backingAlignedRect(
            NSRect(x: contentMaxX - size.width, y: y, width: size.width, height: size.height),
            options: PickerViewGeometry.pixelAlignment)
        return label.frame.minX
    }

    /// Centred in its room between the subject and the hash.
    private func layoutCopyButton() {
        let side = PickerCopyButton.side
        copyButton.frame = backingAlignedRect(
            NSRect(
                x: hashLabel.frame.minX - (Self.copyRoom + side) / 2, y: name.frame.midY - side / 2, width: side,
                height: side),
            options: PickerViewGeometry.pixelAlignment)
        // A reused cell's button may have moved out from under the pointer.
        copyButton.refreshHover(animated: false)
    }
}
