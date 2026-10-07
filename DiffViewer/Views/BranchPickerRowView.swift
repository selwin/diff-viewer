import AppKit

/// A branch row: a round icon tile, the name with a copy button after it over
/// `author · time`, and on the right its status and the Pull/Push pills.
/// The copy button and pills show on the highlighted row; pills also stay
/// while their operation runs. In Switch a highlighted row's status fades out as its
/// pills fade in, only when the pills show; in Merge the preview stays. The current branch's row
/// takes no highlight, so its copy button shows while the pointer is over it. As a table
/// cell it stays an accessibility cell; a press, or the named accessibility action,
/// activates the row, and the copy and the pills' actions are offered beside it.
final class BranchPickerRowView: NSTableCellView, PickerRowAccessoryHosting {
    static let identifier = NSUserInterfaceItemIdentifier("BranchPickerRowView")

    /// The least room the name keeps; the trailing items give way first.
    static let nameMinimum: CGFloat = 72
    private static let tileGap: CGFloat = 12
    private static let lineGap: CGFloat = 1
    /// Between the name and the copy button, whose hover fill already pads the icon.
    private static let copyGap: CGFloat = 0
    private static let animationDuration: TimeInterval = 0.18
    /// A merge preview arriving fades in this quickly, so it reads as settling, not flashing.
    private static let previewFadeDuration: TimeInterval = 0.12

    /// Which of the status and the pills are shown, or fading in.
    private struct TrailingState: Equatable {
        var syncButtons: Bool
        var status: Bool
    }

    /// Set by the table's owner; nil on rows that cannot be activated.
    var onActivate: (() -> Void)?

    /// The pills. Take the space they need only while shown; see `showSyncButtons`.
    var syncButtons: BranchRowSyncButtons? {
        didSet {
            guard syncButtons !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let syncButtons { addSubview(syncButtons) }
            needsLayout = true
        }
    }

    /// Copies the name the row shows, remote prefix included.
    let copyButton = PickerCopyButton(label: "Copy Branch Name")

    /// The copy button and pills: the table sends clicks on them to the buttons, never to
    /// the row.
    var accessories: [NSView] {
        syncButtons.map { [copyButton, $0] } ?? [copyButton]
    }

    /// What is shown, or fading in; see `showSyncButtons`.
    private var shown = TrailingState(syncButtons: false, status: true)
    /// Where a running fade started; `layout()` leaves the status and pills to it.
    private var fadingFrom: TrailingState?
    /// Whether the name's line has room for the copy button; set by `layout()`.
    private var copyButtonFits = false
    /// Bumped by every show or hide, so a finished fade only applies if nothing replaced it.
    private var animationGeneration = 0

    private var isHighlighted = false
    /// Set before `showSyncButtons`, which shows or fades the status to match.
    private var hidesStatus = false

    private let tile = PickerRowIconTile(frame: .zero)
    private let name = PickerLabel.make(font: PickerStyle.nameFont, color: .labelColor)
    private let subtitle = PickerLabel.make(font: PickerStyle.metaFont, color: PickerStyle.meta)
    private let status = BranchRowStatusView(frame: .zero)
    private var row: BranchPickerRow?
    private var accessibilityActionName = "Switch to branch"
    /// Only the current row reads it, to show its copy button.
    private var isPointerInside = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
        // Like the pills: the search field keeps the keyboard.
        copyButton.refusesFirstResponder = true
        for view in [tile, name, copyButton, subtitle, status] { addSubview(view) }
        // `.activeAlways`: a scripted launch never makes the popover key.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// A reused cell starts from its final state: nothing animates across rows. The
    /// container passes what depends on the tab: the right-edge words, why the row is
    /// blocked, and what its activation is called.
    func configure(
        _ row: BranchPickerRow, trailing: BranchRowLabel?, blockedReason: String?, actionName: String
    ) {
        self.row = row
        stopAnimating()
        tile.configure(Self.tileGlyph(for: row.kind))
        name.attributedStringValue = Self.attributedName(row)
        subtitle.stringValue = row.subtitle
        copyButton.configure(text: row.name)
        status.configure(trailing)
        // Reused pills start full; `layout()` compacts them if the row is crowded.
        syncButtons?.reservesShortcutWidth = true
        toolTip = blockedReason
        accessibilityActionName = actionName
        // A status hidden under the pills is still read.
        let described = [row.name, row.kind == .current ? "Current branch" : "", row.subtitle, trailing?.text ?? ""]
        setAccessibilityLabel(described.filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityHelp(blockedReason)
        refreshPointer()
        needsLayout = true
    }

    /// What the highlight shows: the copy button, and no status when the pills take its room.
    /// The status changes with the next `showSyncButtons`, which fades it alongside the pills.
    func setHighlight(_ highlighted: Bool, hidesStatus: Bool) {
        isHighlighted = highlighted
        self.hidesStatus = hidesStatus
        updateCopyButton()
    }

    /// Redraws the drawn parts with the current accessibility display options.
    func refreshRendering() {
        tile.needsDisplay = true
        status.refreshRendering()
        syncButtons?.refreshRendering()
        // A Reduce Motion change mid-fade should not leave it running.
        if fadingFrom != nil { stopAnimating() }
    }

    /// Fades in the right-edge words of a preview that just arrived. Reduce Motion shows
    /// them at once.
    func fadeInTrailing() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = status.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = status.alphaValue
        animation.duration = Self.previewFadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "previewFade")
    }

    /// The one place the copy button's visibility is set: on the highlighted row, or the
    /// current row under the pointer since it takes no highlight, when it fits. Called
    /// when any of those change.
    private func updateCopyButton() {
        let isShown = isHighlighted || (row?.kind == .current && isPointerInside)
        copyButton.isHidden = !(isShown && copyButtonFits)
    }

    // MARK: Pointer

    override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    /// A reused or moved cell gets no exit event, so it reads the pointer again.
    private func refreshPointer() {
        guard let window else { return setPointerInside(false) }
        setPointerInside(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    private func setPointerInside(_ inside: Bool) {
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        updateCopyButton()
    }

    /// The branch glyph, a cloud for a remote-only branch, or the checkmark for the current one.
    private static func tileGlyph(for kind: BranchPickerRow.Kind) -> PickerRowIconTile.Glyph {
        switch kind {
        case .current: .current
        case .remoteOnly:
            .init(
                image: .symbol("cloud", pointSize: 14, weight: .medium), tint: .secondaryLabelColor,
                fill: PickerStyle.tileFill)
        case .local: .init(image: .asset(.gitBranch, side: 14), tint: .secondaryLabelColor, fill: PickerStyle.tileFill)
        }
    }

    private static func attributedName(_ row: BranchPickerRow) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSMutableAttributedString(
            string: row.name,
            attributes: [
                .font: PickerStyle.nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ])
        for range in row.matchedRanges {
            string.addAttribute(.font, value: PickerStyle.matchFont, range: NSRange(range, in: row.name))
        }
        return string
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
                NSAccessibilityCustomAction(name: accessibilityActionName) { [weak self] in
                    self?.accessibilityPerformPress() ?? false
                })
        }
        if row != nil {
            actions.append(
                NSAccessibilityCustomAction(name: "Copy branch name") { [weak self] in
                    guard let self else { return false }
                    copyButton.copyText()
                    return true
                })
        }
        actions += syncButtons?.accessibilityCustomActions() ?? []
        return actions.isEmpty ? nil : actions
    }

    // MARK: Pills

    /// Shows or hides the pills, and the status as `setHighlight` asked. Animated, what
    /// changes fades: what appears takes its final place first, and what leaves stays put.
    /// A change mid-fade starts from what is on screen. Hidden pills take no clicks, and
    /// fading-out ones refuse them.
    func showSyncButtons(_ shownPills: Bool, animated: Bool) {
        let target = TrailingState(syncButtons: shownPills && syncButtons != nil, status: !hidesStatus)
        let from = shown
        shown = target
        // Reduce Motion snaps, like the table's row fades.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard target != from, animated, !reduceMotion, syncButtons != nil, window != nil, !bounds.isEmpty else {
            // A running fade already heads for this state; otherwise snap.
            if !(fadingFrom != nil && target == from) { stopAnimating() }
            return
        }
        animationGeneration += 1
        let generation = animationGeneration
        let frames = trailingFrames(for: target, layout: trailingLayout(for: target))
        // The name keeps clear of what is still leaving.
        fadingFrom = from
        needsLayout = true

        // Explicit animations with explicit start values: `animator()` would fade in from the
        // last committed alpha, not from the zero just set on hidden views.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.animationGeneration else { return }
                self.finishAnimating()
            }
        }
        if let syncButtons, target.syncButtons != from.syncButtons {
            syncButtons.acceptsClicks = target.syncButtons
            fade(syncButtons, in: target.syncButtons, to: frames.syncButtons)
        }
        if target.status != from.status {
            fade(status, in: target.status, to: frames.status)
        }
        CATransaction.commit()
    }

    /// Pills and status come in slowly and leave quickly, so the two never read as stacked.
    private func fade(_ view: NSView, in appearing: Bool, to frame: NSRect?) {
        let opacity = view.isHidden ? 0 : takeOnScreenOpacity(of: view)
        view.isHidden = false
        if appearing, let frame { view.frame = frame }
        view.alphaValue = appearing ? 1 : 0
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = opacity
        animation.toValue = appearing ? 1 : 0
        animation.duration = Self.animationDuration
        animation.timingFunction = CAMediaTimingFunction(name: appearing ? .easeIn : .easeOut)
        view.layer?.add(animation, forKey: "opacity")
    }

    /// Ends any fade and puts the status and pills in their final state.
    private func stopAnimating() {
        animationGeneration += 1
        status.layer?.removeAllAnimations()
        syncButtons?.layer?.removeAllAnimations()
        finishAnimating()
    }

    private func finishAnimating() {
        fadingFrom = nil
        syncButtons?.alphaValue = 1
        syncButtons?.isHidden = !shown.syncButtons
        syncButtons?.acceptsClicks = true
        status.alphaValue = 1
        status.isHidden = !shown.status
        needsLayout = true
    }

    /// What `view`'s layer shows now, mid-fade or not. Drops its animations, so the next
    /// one starts from there.
    private func takeOnScreenOpacity(of view: NSView) -> CGFloat {
        guard let layer = view.layer else { return view.alphaValue }
        let opacity = CGFloat((layer.presentation() ?? layer).opacity)
        layer.removeAllAnimations()
        return opacity
    }

    // MARK: Layout

    /// Where the name starts.
    private static let textX =
        PickerStyle.highlightInset + PickerStyle.contentInset + PickerStyle.iconTileSize + tileGap

    /// The text line's width in a row `rowWidth` wide: from the name's start to the content's
    /// trailing edge.
    static func lineWidth(rowWidth: CGFloat) -> CGFloat {
        rowWidth - PickerStyle.highlightInset - PickerStyle.contentInset - textX
    }

    private var textX: CGFloat { Self.textX }

    private var contentMaxX: CGFloat { textX + Self.lineWidth(rowWidth: bounds.width) }

    /// How the line is shared with `state` shown, from natural widths alone.
    private func trailingLayout(for state: TrailingState) -> BranchRowTrailingLayout {
        let pills = state.syncButtons ? syncButtons : nil
        let widths = BranchRowTrailingLayout.Widths(
            status: state.status ? status.naturalSize.width : 0,
            syncPills: pills?.width(reservingShortcuts: true) ?? 0,
            compactSyncPills: pills?.width(reservingShortcuts: false) ?? 0,
            copyButton: Self.copyGap + PickerCopyButton.side, gap: PickerStyle.trailingGap)
        return .make(available: Self.lineWidth(rowWidth: bounds.width), nameMinimum: Self.nameMinimum, widths: widths)
    }

    /// Right to left from the content edge: the pills, the status. One
    /// place, so a fade ends exactly where a plain layout would put things.
    private func trailingFrames(
        for state: TrailingState, layout: BranchRowTrailingLayout
    ) -> (syncButtons: NSRect?, status: NSRect) {
        var right = contentMaxX
        func place(width: CGFloat, height: CGFloat) -> NSRect {
            let frame = backingAlignedRect(
                NSRect(x: right - width, y: (bounds.height - height) / 2, width: width, height: height),
                options: PickerViewGeometry.pixelAlignment)
            right = frame.minX - PickerStyle.trailingGap
            return frame
        }
        var pillsFrame: NSRect?
        if state.syncButtons, let syncButtons {
            pillsFrame = place(
                width: syncButtons.width(reservingShortcuts: layout.reservesShortcutWidth),
                height: syncButtons.intrinsicContentSize.height)
        }
        var statusFrame = NSRect.zero
        if state.status, layout.statusWidth > 0 {
            statusFrame = place(width: layout.statusWidth, height: status.naturalSize.height)
        }
        return (pillsFrame, statusFrame)
    }

    // The two text lines are centred as a block; the trailing items are centred on the
    // row, measured first so the name takes what is left.
    override func layout() {
        super.layout()
        let side = PickerStyle.iconTileSize
        tile.frame = NSRect(
            x: PickerStyle.highlightInset + PickerStyle.contentInset,
            y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        let final = trailingLayout(for: shown)
        // Pills fading out keep the width they had.
        if shown.syncButtons { syncButtons?.reservesShortcutWidth = final.reservesShortcutWidth }
        // While a fade runs, the name takes the narrower of its two layouts, so it never
        // runs under what is still on screen.
        var nameLayout = final
        if let fadingFrom {
            let start = trailingLayout(for: fadingFrom)
            if start.nameWidth < final.nameWidth { nameLayout = start }
        }
        layoutText(nameLayout)
        let frames = trailingFrames(for: shown, layout: final)
        // A running fade already ends on these frames; setting them here would snap it.
        guard fadingFrom == nil else { return }
        if let frame = frames.syncButtons { syncButtons?.frame = frame }
        status.frame = frames.status
    }

    /// The name, truncating, then the copy button, over the subtitle. The button's room is
    /// kept while it is hidden, so the name does not shift as the highlight moves; a
    /// crowded line gives it up.
    private func layoutText(_ layout: BranchRowTrailingLayout) {
        let nameHeight = PickerViewGeometry.naturalSize(of: name).height
        let subtitleHeight = PickerViewGeometry.naturalSize(of: subtitle).height
        let top = ((bounds.height - nameHeight - Self.lineGap - subtitleHeight) / 2).rounded()
        let side = PickerCopyButton.side
        copyButtonFits = layout.showsCopyButton
        let room = max(layout.nameWidth, 0)
        let nameWidth = copyButtonFits ? min(PickerViewGeometry.naturalSize(of: name).width, room) : room
        name.frame = NSRect(x: textX, y: top, width: nameWidth, height: nameHeight)
        copyButton.frame = backingAlignedRect(
            NSRect(x: name.frame.maxX + Self.copyGap, y: top + (nameHeight - side) / 2, width: side, height: side),
            options: PickerViewGeometry.pixelAlignment)
        let lineWidth = room + (copyButtonFits ? Self.copyGap + side : 0)
        subtitle.frame = NSRect(
            x: textX, y: name.frame.maxY + Self.lineGap, width: lineWidth, height: subtitleHeight)
        updateCopyButton()
        // A reused cell's button may have moved out from under the pointer.
        copyButton.refreshHover(animated: false)
    }
}
