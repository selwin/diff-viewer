import AppKit

/// A stash row: a round archive tile, the message with its `+X −Y` line counts over
/// `branch · time`, and `Tracked only` when the stash has an untracked-files parent. The
/// displayed stash's tile is the accent checkmark. A press, or the named accessibility
/// action, activates the row.
final class StashPickerRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("StashPickerRowView")

    private static let tileGap: CGFloat = 12
    private static let lineGap: CGFloat = 1
    private static let minusSign = "\u{2212}"
    private static let stashGlyph = PickerRowIconTile.Glyph(
        image: .symbol("archivebox", pointSize: 13, weight: .medium), tint: .secondaryLabelColor,
        fill: PickerStyle.tileFill)
    private static let churnFont = NSFont.monospacedDigitSystemFont(
        ofSize: PickerStyle.rowStatusFont.pointSize, weight: .medium)
    private static let regularNameFont = PickerStyle.nameFont
    /// For git's own "WIP on …" message, so a message the reader wrote stands out.
    private static let defaultNameFont: NSFont = {
        let descriptor = PickerStyle.nameFont.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: PickerStyle.nameFont.pointSize) ?? PickerStyle.nameFont
    }()

    /// Set by the table's owner.
    var onActivate: (() -> Void)?

    private let tile = PickerRowIconTile(frame: .zero)
    private let name = PickerLabel.make(font: PickerStyle.nameFont, color: .labelColor)
    private let churn = PickerLabel.make(font: churnFont, color: PickerStyle.meta, alignment: .right)
    private let branch = PickerLabel.make(font: PickerStyle.metaFont, color: PickerStyle.meta)
    private let time = PickerLabel.make(font: PickerStyle.metaFont, color: PickerStyle.meta)
    private let detail = PickerLabel.make(font: PickerStyle.rowStatusFont, color: PickerStyle.meta, alignment: .right)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
        for view in [tile, name, churn, branch, time, detail] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(_ row: StashPickerRow) {
        let entry = row.entry
        tile.configure(row.isDisplayed ? .current : Self.stashGlyph)
        name.stringValue = entry.message
        name.font = entry.hasDefaultMessage ? Self.defaultNameFont : Self.regularNameFont
        // A stash of only untracked files has no tracked lines to count, and `+0 −0` says nothing.
        let churnText = entry.churn.flatMap { $0.additions + $0.deletions == 0 ? nil : Self.churnText($0) }
        if let churnText {
            churn.attributedStringValue = churnText
        } else {
            churn.stringValue = ""
        }
        branch.stringValue = entry.sourceBranch ?? ""
        // The labels' own padding spaces the dot.
        time.stringValue = entry.sourceBranch == nil ? row.timeText : "· \(row.timeText)"
        detail.stringValue = entry.hasUntrackedParent ? "Tracked only" : ""

        var parts = [entry.message]
        if row.isDisplayed { parts.append("current") }
        if let sourceBranch = entry.sourceBranch { parts.append(sourceBranch) }
        parts.append(row.timeText)
        if let churn = entry.churn {
            parts.append("\(churn.additions) additions, \(churn.deletions) deletions")
        }
        if entry.hasUntrackedParent { parts.append("tracked changes only") }
        setAccessibilityLabel(parts.joined(separator: ", "))
        needsLayout = true
    }

    /// Additions in green and deletions in red, which the colours alone must not carry:
    /// the signs do too.
    private static func churnText(_ churn: StashEntry.Churn) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: "+\(churn.additions)",
            attributes: [.font: churnFont, .foregroundColor: DiffTheme.addedCount])
        text.append(
            NSAttributedString(
                string: " \(minusSign)\(churn.deletions)",
                attributes: [.font: churnFont, .foregroundColor: DiffTheme.deletedCount]))
        return text
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
        guard onActivate != nil else { return nil }
        return [
            NSAccessibilityCustomAction(name: "Show") { [weak self] in
                self?.accessibilityPerformPress() ?? false
            }
        ]
    }

    // MARK: Layout

    /// Where the text starts, past the tile.
    private static let textX =
        PickerStyle.highlightInset + PickerStyle.contentInset + PickerStyle.iconTileSize + tileGap

    private var contentMaxX: CGFloat { bounds.width - PickerStyle.highlightInset - PickerStyle.contentInset }

    /// The tile is centred on the row, and so is the text as a two-line block. Each line is
    /// laid out right to left: the first's line counts, then the message, truncating; the
    /// second's `Tracked only`, `· time` at its natural width, then the branch, truncating.
    override func layout() {
        super.layout()
        let side = PickerStyle.iconTileSize
        tile.frame = NSRect(
            x: PickerStyle.highlightInset + PickerStyle.contentInset, y: ((bounds.height - side) / 2).rounded(),
            width: side, height: side)

        let nameHeight = PickerViewGeometry.naturalSize(of: name).height
        let metaHeight = PickerViewGeometry.naturalSize(of: branch).height
        let top = ((bounds.height - nameHeight - Self.lineGap - metaHeight) / 2).rounded()

        let nameMaxX =
            placeFlushRight(churn, onBaselineOf: name, lineY: top, lineHeight: nameHeight).map {
                $0 - PickerStyle.trailingGap
            } ?? contentMaxX
        name.frame = NSRect(x: Self.textX, y: top, width: max(nameMaxX - Self.textX, 0), height: nameHeight)

        let metaY = name.frame.maxY + Self.lineGap
        let metaMaxX =
            placeFlushRight(detail, onBaselineOf: branch, lineY: metaY, lineHeight: metaHeight).map {
                $0 - PickerStyle.trailingGap
            } ?? contentMaxX
        let available = max(metaMaxX - Self.textX, 0)
        let timeWidth = min(PickerViewGeometry.naturalSize(of: time).width, available)
        let branchWidth =
            branch.stringValue.isEmpty
            ? 0 : min(PickerViewGeometry.naturalSize(of: branch).width, available - timeWidth)
        branch.frame = NSRect(x: Self.textX, y: metaY, width: branchWidth, height: metaHeight)
        time.frame = backingAlignedRect(
            NSRect(x: branch.frame.maxX, y: metaY, width: timeWidth, height: metaHeight),
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
}
