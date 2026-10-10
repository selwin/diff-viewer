import AppKit

/// A stash row: a round archive tile, and the message with its `+X −Y` line counts over
/// `branch · time`. The displayed stash's tile is the accent checkmark. A press, or the
/// named accessibility action, activates the row. The highlighted row, and one whose action
/// runs, trades its line counts for Pop and Drop… pills.
final class StashPickerRowView: NSTableCellView, PickerRowAccessoryHosting {
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

    private static let pillHeight: CGFloat = 24
    private static let pillGap: CGFloat = 6

    /// Set by the table's owner.
    var onActivate: (() -> Void)?
    /// Set by the table's owner; called with the entry this cell last showed.
    var onPop: ((StashEntry) -> Void)?
    var onDrop: ((StashEntry) -> Void)?

    private let tile = PickerRowIconTile(frame: .zero)
    private let name = PickerLabel.make(font: PickerStyle.nameFont, color: .labelColor)
    private let churn = PickerLabel.make(font: churnFont, color: PickerStyle.meta, alignment: .right)
    private let branch = PickerLabel.make(font: PickerStyle.metaFont, color: PickerStyle.meta)
    private let time = PickerLabel.make(font: PickerStyle.metaFont, color: PickerStyle.meta)
    /// Holds both pills, so a click in the gap between them doesn't activate the row either.
    private let pills = NSView(frame: .zero)
    private let popButton = PickerPillButton(title: "Pop", height: pillHeight, focusMargin: 0, surface: .neutral)
    private let dropButton = PickerPillButton(title: "Drop…", height: pillHeight, focusMargin: 0, surface: .neutral)
    private var entry: StashEntry?
    private var buttons: (pop: PickerButtonState, drop: PickerButtonState) = (.hidden, .hidden)

    /// The pills: the table sends clicks on them to the buttons, never to the row.
    var accessories: [NSView] { [pills] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
        pills.clipsToBounds = true
        popButton.look = .primary
        dropButton.look = .destructive
        for button in [popButton, dropButton] {
            // The search field keeps the keyboard; VoiceOver uses the row's custom actions.
            button.refusesFirstResponder = true
            button.focusRingType = .none
            button.target = self
            pills.addSubview(button)
        }
        popButton.action = #selector(popClicked)
        dropButton.action = #selector(dropClicked)
        for view in [tile, name, churn, branch, time, pills] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// `buttons` nil hides the pills. They show on the highlighted row, and on one whose
    /// action runs so its spinner stays in sight.
    func configure(
        _ row: StashPickerRow, buttons: (pop: PickerButtonState, drop: PickerButtonState)?, isHighlighted: Bool
    ) {
        let entry = row.entry
        self.entry = entry
        self.buttons = buttons ?? (.hidden, .hidden)
        popButton.apply(self.buttons.pop, title: "Pop")
        dropButton.apply(self.buttons.drop, title: "Drop…")
        let running = self.buttons.pop == .running || self.buttons.drop == .running
        pills.isHidden = buttons == nil || !(isHighlighted || running)
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

        var parts = [entry.message]
        if row.isDisplayed { parts.append("current") }
        if let sourceBranch = entry.sourceBranch { parts.append(sourceBranch) }
        parts.append(row.timeText)
        if let churn = entry.churn {
            parts.append("\(churn.additions) additions, \(churn.deletions) deletions")
        }
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

    @objc private func popClicked() {
        if let entry { onPop?(entry) }
    }

    @objc private func dropClicked() {
        if let entry { onDrop?(entry) }
    }

    /// Redraws the tile and pills with the current accessibility display options.
    func refreshRendering() {
        tile.needsDisplay = true
        popButton.refreshRendering()
        dropButton.refreshRendering()
    }

    // MARK: Accessibility

    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    /// Pop and Drop are offered while enabled, whether or not their pills show, and refuse
    /// once they no longer are.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard onActivate != nil else { return nil }
        var actions = [
            NSAccessibilityCustomAction(name: "Show") { [weak self] in
                self?.accessibilityPerformPress() ?? false
            }
        ]
        if buttons.pop == .enabled {
            actions.append(
                NSAccessibilityCustomAction(name: "Pop stash") { [weak self] in
                    guard let self, buttons.pop == .enabled else { return false }
                    popClicked()
                    return true
                })
        }
        if buttons.drop == .enabled {
            actions.append(
                NSAccessibilityCustomAction(name: "Drop stash") { [weak self] in
                    guard let self, buttons.drop == .enabled else { return false }
                    dropClicked()
                    return true
                })
        }
        return actions
    }

    // MARK: Layout

    /// Where the text starts, past the tile.
    private static let textX =
        PickerStyle.highlightInset + PickerStyle.contentInset + PickerStyle.iconTileSize + tileGap

    private var contentMaxX: CGFloat { bounds.width - PickerStyle.highlightInset - PickerStyle.contentInset }

    /// The tile is centred on the row, and so is the text as a two-line block. The first
    /// line is laid out right to left: the line counts, then the message, truncating. On the
    /// second, the branch truncates so `· time` keeps its natural width. Shown pills,
    /// centred on the row, take the line counts' place and both lines end before them.
    override func layout() {
        super.layout()
        let side = PickerStyle.iconTileSize
        tile.frame = NSRect(
            x: PickerStyle.highlightInset + PickerStyle.contentInset, y: ((bounds.height - side) / 2).rounded(),
            width: side, height: side)

        let nameHeight = PickerViewGeometry.naturalSize(of: name).height
        let metaHeight = PickerViewGeometry.naturalSize(of: branch).height
        let top = ((bounds.height - nameHeight - Self.lineGap - metaHeight) / 2).rounded()

        let pillsMinX = layoutPills()
        churn.isHidden = pillsMinX != nil
        let textMaxX = pillsMinX.map { $0 - PickerStyle.trailingGap } ?? contentMaxX
        let churnMinX =
            pillsMinX == nil ? placeFlushRight(churn, onBaselineOf: name, lineY: top, lineHeight: nameHeight) : nil
        let nameMaxX = churnMinX.map { $0 - PickerStyle.trailingGap } ?? textMaxX
        name.frame = NSRect(x: Self.textX, y: top, width: max(nameMaxX - Self.textX, 0), height: nameHeight)

        let metaY = name.frame.maxY + Self.lineGap
        let available = max(textMaxX - Self.textX, 0)
        let timeWidth = min(PickerViewGeometry.naturalSize(of: time).width, available)
        let branchWidth =
            branch.stringValue.isEmpty
            ? 0 : min(PickerViewGeometry.naturalSize(of: branch).width, available - timeWidth)
        branch.frame = NSRect(x: Self.textX, y: metaY, width: branchWidth, height: metaHeight)
        time.frame = backingAlignedRect(
            NSRect(x: branch.frame.maxX, y: metaY, width: timeWidth, height: metaHeight),
            options: PickerViewGeometry.pixelAlignment)
    }

    /// Puts the shown pills against the content's trailing edge, centred on the row.
    /// Returns where they start, or nil while they are hidden.
    private func layoutPills() -> CGFloat? {
        guard !pills.isHidden else { return nil }
        let popSize = popButton.intrinsicContentSize
        let dropSize = dropButton.intrinsicContentSize
        let width = popSize.width + Self.pillGap + dropSize.width
        pills.frame = backingAlignedRect(
            NSRect(
                x: contentMaxX - width, y: (bounds.height - Self.pillHeight) / 2, width: width,
                height: Self.pillHeight),
            options: PickerViewGeometry.pixelAlignment)
        popButton.frame = NSRect(x: 0, y: 0, width: popSize.width, height: Self.pillHeight)
        dropButton.frame = NSRect(
            x: popSize.width + Self.pillGap, y: 0, width: dropSize.width, height: Self.pillHeight)
        return pills.frame.minX
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
