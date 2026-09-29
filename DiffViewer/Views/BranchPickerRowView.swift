import AppKit

/// A branch row: icon, name with a copy button after it, `author · time`, status text, and
/// the Pull/Push pills. The copy button and pills show on the highlighted row; pills also
/// stay while their operation runs. As the highlight moves, the pills fade and the status
/// slides to make room. As a table cell it stays an accessibility cell; a press, or the
/// named accessibility action, activates the row, and the copy and the pills' actions are
/// offered beside it.
final class BranchPickerRowView: NSTableCellView, PickerRowAccessoryHosting {
    static let identifier = NSUserInterfaceItemIdentifier("BranchPickerRowView")

    private static let matchFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    private static let accentStatusFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let iconSize: CGFloat = 14
    private static let iconGap: CGFloat = 9
    /// Between the name and the copy button, whose hover fill already pads the icon.
    private static let copyGap: CGFloat = 0
    private static let animationDuration: TimeInterval = 0.18

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

    /// Whether the pills are shown, or fading in; false while they fade out.
    private var areSyncButtonsShown = false
    /// Whether the name's line has room for the copy button; set by `layout()`.
    private var copyButtonFits = false
    /// Bumped by every show or hide, so a finished fade only applies if nothing replaced it.
    private var animationGeneration = 0
    /// While set, `layout()` leaves the status and pills to the running animation.
    private var isAnimating = false

    /// On the accent fill every part turns white.
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { applyColors() } }
    }

    private let icon = NSImageView()
    private let name = PickerLabel.make(font: PickerMetrics.nameFont, color: .labelColor)
    private let subtitle = PickerLabel.make(font: PickerMetrics.subtitleFont, color: .secondaryLabelColor)
    private let status = PickerLabel.make(
        font: PickerMetrics.statusFont, color: .secondaryLabelColor, alignment: .right)
    private var row: BranchPickerRow?
    private var accessibilityActionName = "Switch to branch"

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        // Like the pills: the search field keeps the keyboard.
        copyButton.refusesFirstResponder = true
        for view in [icon, name, copyButton, subtitle, status] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// A reused cell starts from its final state: nothing animates across rows.
    func configure(_ row: BranchPickerRow) {
        self.row = row
        stopAnimating()
        let symbol: NSImage? =
            switch row.kind {
            case .current: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            case .remoteOnly: NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
            case .local: NSImage(resource: .gitBranch)
            }
        icon.image = symbol?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        subtitle.stringValue = row.subtitle
        copyButton.configure(text: row.name)
        status.stringValue = row.status.text
        toolTip = row.blockedReason
        accessibilityActionName = row.kind == .remoteOnly ? "Check out branch" : "Switch to branch"
        let described = [row.name, row.kind == .current ? "current" : "", row.subtitle, row.status.text]
        setAccessibilityLabel(described.filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityHelp(row.blockedReason)
        applyColors()
        needsLayout = true
    }

    /// Everything that depends on the highlight: the name's attributes included, since a
    /// search's emphasis is drawn in the same colour as the rest of the name.
    private func applyColors() {
        guard let row else { return }
        let primary: NSColor = isHighlighted ? .white : .labelColor
        let secondary: NSColor = isHighlighted ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        name.attributedStringValue = Self.attributedName(row, color: primary)
        subtitle.textColor = secondary
        if row.status.isAccent {
            status.textColor = isHighlighted ? .white : .controlAccentColor
        } else {
            status.textColor = secondary
        }
        status.font = row.status.isAccent ? Self.accentStatusFont : PickerMetrics.statusFont
        icon.contentTintColor =
            isHighlighted ? .white : (row.kind == .current ? .controlAccentColor : .secondaryLabelColor)
        syncButtons?.isOnAccent = isHighlighted
        updateCopyButton()
    }

    /// The one place the copy button's visibility is set: on the highlighted row, when it
    /// fits. Called when either changes.
    private func updateCopyButton() {
        copyButton.isOnAccent = isHighlighted
        copyButton.isHidden = !(isHighlighted && copyButtonFits)
    }

    private static func attributedName(_ row: BranchPickerRow, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let base = row.kind == .current ? PickerMetrics.currentNameFont : PickerMetrics.nameFont
        let string = NSMutableAttributedString(
            string: row.name, attributes: [.font: base, .foregroundColor: color, .paragraphStyle: paragraph])
        for range in row.matchedRanges {
            string.addAttribute(.font, value: matchFont, range: NSRange(range, in: row.name))
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

    /// Shows or hides the pills. Animated, the pills fade and the status slides; a change
    /// mid-animation starts from what is on screen. Hidden pills take no clicks, and
    /// fading-out ones refuse them.
    func showSyncButtons(_ shown: Bool, animated: Bool) {
        let changed = shown != areSyncButtonsShown
        areSyncButtonsShown = shown
        guard let syncButtons else { return stopAnimating() }
        guard changed, animated, window != nil, !bounds.isEmpty else {
            // A running animation already heads for this state; otherwise snap.
            if !(isAnimating && !changed) { stopAnimating() }
            return
        }
        animationGeneration += 1
        let generation = animationGeneration
        let target = trailingFrames(showingSyncButtons: shown)
        let statusX = takeOnScreenState(of: status).x
        let opacity = syncButtons.isHidden ? 0 : takeOnScreenState(of: syncButtons).opacity
        syncButtons.isHidden = false
        if shown, let frame = target.syncButtons { syncButtons.frame = frame }
        syncButtons.acceptsClicks = shown
        isAnimating = true
        // The name takes its narrower width now: see `layout()`.
        needsLayout = true

        // Explicit animations with explicit start values: `animator()` would fade in from the
        // last committed alpha, not from the zero just set on hidden pills.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.animationGeneration else { return }
                self.finishAnimating()
            }
        }
        syncButtons.alphaValue = shown ? 1 : 0
        // Pills come in slowly and leave quickly, so they stay faint while the status moves
        // past them.
        add(keyPath: "opacity", from: opacity, to: shown ? 1 : 0, timing: shown ? .easeIn : .easeOut, to: syncButtons)
        status.frame = target.status
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = status.layer {
            add(keyPath: "position.x", from: statusX, to: layer.position.x, timing: .easeOut, to: status)
        }
        CATransaction.commit()
    }

    private func add(
        keyPath: String, from: CGFloat, to value: CGFloat, timing: CAMediaTimingFunctionName, to view: NSView
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = Self.animationDuration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        view.layer?.add(animation, forKey: keyPath)
    }

    /// Ends any animation and puts the status and pills in their final state.
    private func stopAnimating() {
        animationGeneration += 1
        status.layer?.removeAllAnimations()
        syncButtons?.layer?.removeAllAnimations()
        finishAnimating()
    }

    private func finishAnimating() {
        isAnimating = false
        syncButtons?.alphaValue = 1
        syncButtons?.isHidden = !areSyncButtonsShown
        syncButtons?.acceptsClicks = true
        needsLayout = true
    }

    /// What `view`'s layer shows now, mid-animation or not, in its superlayer's coordinates.
    /// Drops its animations, so the next one starts from there.
    private func takeOnScreenState(of view: NSView) -> (x: CGFloat, opacity: CGFloat) {
        guard let layer = view.layer else { return (view.frame.midX, view.alphaValue) }
        let shown = layer.presentation() ?? layer
        let state = (x: shown.position.x, opacity: CGFloat(shown.opacity))
        layer.removeAllAnimations()
        return state
    }

    // MARK: Layout

    /// Where the pills and status go with the pills shown or not, and where the name must
    /// stop. One place, so an animation ends exactly where a plain layout would put things.
    private func trailingFrames(
        showingSyncButtons: Bool
    ) -> (syncButtons: NSRect?, status: NSRect, textMaxX: CGFloat) {
        var rightEdge = bounds.width - PickerMetrics.rowInset - PickerMetrics.contentInset
        var syncButtonsFrame: NSRect?
        if showingSyncButtons, let syncButtons {
            let size = syncButtons.intrinsicContentSize
            let frame = backingAlignedRect(
                NSRect(
                    x: rightEdge - size.width, y: (bounds.height - size.height) / 2, width: size.width,
                    height: size.height),
                options: PickerViewGeometry.pixelAlignment)
            syncButtonsFrame = frame
            rightEdge = frame.minX - PickerMetrics.trailingGap
        }
        var statusFrame = NSRect.zero
        if !status.stringValue.isEmpty {
            let size = PickerViewGeometry.naturalSize(of: status)
            statusFrame = backingAlignedRect(
                NSRect(
                    x: rightEdge - size.width, y: (bounds.height - size.height) / 2, width: size.width,
                    height: size.height),
                options: PickerViewGeometry.pixelAlignment)
            rightEdge = statusFrame.minX - PickerMetrics.trailingGap
        }
        return (syncButtonsFrame, statusFrame, rightEdge)
    }

    // The two text lines are centred as a block; the status and pills are centred on the
    // row, measured first so the name takes what is left.
    override func layout() {
        super.layout()
        let leading = PickerMetrics.rowInset + PickerMetrics.contentInset
        let nameHeight = PickerViewGeometry.naturalSize(of: name).height
        let subtitleHeight = PickerViewGeometry.naturalSize(of: subtitle).height
        let top = ((bounds.height - nameHeight - PickerMetrics.lineGap - subtitleHeight) / 2).rounded()
        icon.frame = NSRect(
            x: leading, y: ((bounds.height - Self.iconSize) / 2).rounded(), width: Self.iconSize,
            height: Self.iconSize)
        let target = trailingFrames(showingSyncButtons: areSyncButtonsShown)
        // Pills fading out still take their room, so the name never runs under them.
        let textMaxX = isAnimating ? trailingFrames(showingSyncButtons: true).textMaxX : target.textMaxX
        let textX = icon.frame.maxX + Self.iconGap
        let textWidth = max(textMaxX - textX, 0)
        layoutName(x: textX, y: top, width: textWidth, height: nameHeight)
        subtitle.frame = NSRect(
            x: textX, y: name.frame.maxY + PickerMetrics.lineGap, width: textWidth, height: subtitleHeight)
        // A running animation already ends on `target`; setting it here would snap it.
        guard !isAnimating else { return }
        if let frame = target.syncButtons { syncButtons?.frame = frame }
        status.frame = target.status
    }

    /// The name, truncating, then the copy button. The button's room is kept while it is
    /// hidden, so the name does not shift as the highlight moves; too narrow a line hides
    /// the button and gives the name all of it.
    private func layoutName(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let side = PickerCopyButton.side
        copyButtonFits = width >= Self.copyGap + side
        let nameWidth =
            copyButtonFits
            ? max(min(PickerViewGeometry.naturalSize(of: name).width, width - Self.copyGap - side), 0) : width
        name.frame = NSRect(x: x, y: y, width: nameWidth, height: height)
        copyButton.frame = backingAlignedRect(
            NSRect(x: name.frame.maxX + Self.copyGap, y: y + (height - side) / 2, width: side, height: side),
            options: PickerViewGeometry.pixelAlignment)
        updateCopyButton()
        // A reused cell's button may have moved out from under the pointer.
        copyButton.refreshHover(animated: false)
    }
}
