import AppKit

/// A branch's Pull and Push buttons, Pull on the left, where Publish takes Push's place on
/// a branch that tracks nothing and Delete takes it on a branch whose upstream is gone.
/// Rows show them as pills on the highlighted row; the header shows the current branch's
/// as larger buttons. Pull is the accent button when it shows, since a diverged branch must
/// pull before it can push; otherwise Push is. A running button keeps its place and its
/// width: the spinner replaces the title rather than the button. The callbacks carry
/// the branch these were configured for, never a row index, so a recycled cell cannot act
/// on another row.
final class BranchRowSyncButtons: NSView {
    enum Style {
        /// Pills on the highlighted row.
        case rowPills
        /// The header's buttons: taller, and focusable.
        case header
    }

    private let style: Style
    /// Between the buttons' frames; header buttons carry their focus ring margins as well.
    private let gap: CGFloat
    let pullButton: SyncPillButton
    let pushButton: SyncPillButton
    private let deleteButton: SyncPillButton
    private var states = RowSyncButtons.hidden
    private var onPull: () -> Void = {}
    private var onPush: () -> Void = {}
    private var onPublish: (String) -> Void = { _ in }
    private var onDelete: () -> Void = {}

    /// Whether the last `configure` asked for the buttons to show; the owner shows or hides
    /// this view accordingly.
    private(set) var shouldShow = false
    /// False while the pills fade out: they take no clicks, as if already hidden.
    var acceptsClicks = true

    init(style: Style) {
        self.style = style
        let isHeader = style == .header
        let height: CGFloat = isHeader ? 24 : 22
        let margin: CGFloat = isHeader ? SyncPillButton.focusRingMargin : 0
        gap = isHeader ? 8 - margin * 2 : 6
        pullButton = SyncPillButton(title: "Pull", height: height, focusMargin: margin)
        pushButton = SyncPillButton(title: "Push", height: height, focusMargin: margin)
        deleteButton = SyncPillButton(title: "Delete…", height: height, focusMargin: margin)
        super.init(frame: .zero)
        pullButton.shortcut = "⇧⌘P"
        pushButton.shortcut = "⌘P"
        clipsToBounds = true
        for button in buttons {
            // Row pills show only on the highlighted row: the search field keeps the
            // keyboard, and VoiceOver uses the row's custom actions. Header buttons take
            // focus for keyboard users. Neither has a key equivalent: Return belongs to
            // the highlighted row, and the picker routes ⌘P and ⇧⌘P itself.
            button.refusesFirstResponder = !isHeader
            button.focusRingType = isHeader ? .default : .none
            button.target = self
            addSubview(button)
        }
        pullButton.action = #selector(pullClicked)
        pushButton.action = #selector(pushClicked)
        deleteButton.action = #selector(deleteClicked)
        deleteButton.look = .destructive
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var buttons: [SyncPillButton] { [pullButton, pushButton, deleteButton] }

    @objc private func pullClicked() { onPull() }
    @objc private func deleteClicked() { onDelete() }
    @objc private func pushClicked() {
        switch states.publish {
        case nil: onPush()
        case let .remote(remote): onPublish(remote)
        case let .menu(items): showPublishMenu(items)
        }
    }

    /// Drops down from the button. A remote being fetched is listed, disabled.
    private func showPublishMenu(_ items: [PublishMenuItem]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Bound now: a refresh can reconfigure this reused view for another branch while
        // the menu is open.
        let publish = onPublish
        for item in items {
            let entry = NSMenuItem(title: item.remote, action: #selector(publishRemoteChosen), keyEquivalent: "")
            entry.target = self
            entry.representedObject = PublishChoice { publish(item.remote) }
            entry.isEnabled = item.isEnabled
            menu.addItem(entry)
        }
        let below = NSPoint(x: 0, y: pushButton.isFlipped ? pushButton.bounds.maxY + 2 : -2)
        menu.popUp(positioning: nil, at: below, in: pushButton)
    }

    @objc private func publishRemoteChosen(_ sender: NSMenuItem) {
        (sender.representedObject as? PublishChoice)?.run()
    }

    // MARK: Shortcuts

    /// ⇧⌘P's click. Returns whether it ran: only an enabled button the reader could click
    /// takes it.
    func pressPull() -> Bool {
        guard canPress(pullButton, state: states.pull) else { return false }
        pullClicked()
        return true
    }

    /// ⌘P's click, as for `pressPull`. A Publish with several remotes opens its menu.
    func pressPush() -> Bool {
        guard canPress(pushButton, state: states.push) else { return false }
        pushClicked()
        return true
    }

    private func canPress(_ button: SyncPillButton, state: PickerButtonState) -> Bool {
        state == .enabled && acceptsClicks && !button.isHiddenOrHasHiddenAncestor
    }

    /// Shows the shortcut glyph on the buttons the keys would press now.
    func setShortcutGlyphs(pull: Bool, push: Bool) {
        pullButton.showsKeyboardShortcut = pull
        pushButton.showsKeyboardShortcut = push
    }

    // swiftlint:disable function_parameter_count
    /// `shouldShow` holds while `isRevealed` or while one of them runs, unless none has
    /// anything to show. `onPublish` takes the branch, then the remote; `onDelete` comes
    /// already bound to the row's branch.
    func configure(
        _ buttons: RowSyncButtons, isRevealed: Bool, branch: String, onPull: @escaping (String) -> Void,
        onPush: @escaping (String) -> Void, onPublish: @escaping (String, String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        states = buttons
        self.onPull = { onPull(branch) }
        self.onPush = { onPush(branch) }
        self.onPublish = { onPublish(branch, $0) }
        self.onDelete = onDelete
        pullButton.apply(buttons.pull, title: "Pull")
        pushButton.apply(buttons.push, title: buttons.pushTitle)
        deleteButton.apply(buttons.delete, title: "Delete…")
        let pullShows = buttons.pull != .hidden
        pullButton.look = pullShows ? .primary : .plain
        pushButton.look = pullShows ? .plain : .primary
        let all = [buttons.pull, buttons.push, buttons.delete]
        shouldShow = (isRevealed || all.contains(.running)) && !all.allSatisfy { $0 == .hidden }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    // swiftlint:enable function_parameter_count

    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsClicks ? super.hitTest(point) : nil
    }

    private var visibleButtons: [SyncPillButton] {
        buttons.filter { !$0.isHidden }
    }

    /// The header's buttons carry margins for their focus rings; the visible shapes exclude them.
    override var alignmentRectInsets: NSEdgeInsets {
        let margin = style == .header ? SyncPillButton.focusRingMargin : 0
        return NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
    }

    override var intrinsicContentSize: NSSize {
        let sizes = visibleButtons.map(\.intrinsicContentSize)
        let width = sizes.map(\.width).reduce(0, +) + gap * CGFloat(max(sizes.count - 1, 0))
        return NSSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for button in visibleButtons {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + gap
        }
    }

    // MARK: Accessibility

    /// The enabled buttons as actions, so the row offers them whether or not they show.
    /// A menu's remotes become one action each, since VoiceOver can't open the menu.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions: [NSAccessibilityCustomAction] = []
        if states.pull == .enabled {
            actions.append(action("Pull") { $0.onPull() })
        }
        if states.push == .enabled {
            switch states.publish {
            case nil:
                actions.append(action(states.pushTitle) { $0.onPush() })
            case let .remote(remote):
                actions.append(action("Publish") { $0.onPublish(remote) })
            case let .menu(items):
                for item in items where item.isEnabled {
                    actions.append(action("Publish to \(item.remote)") { $0.onPublish(item.remote) })
                }
            }
        }
        if states.delete == .enabled {
            actions.append(action("Delete branch") { $0.onDelete() })
        }
        return actions
    }

    private func action(
        _ name: String, _ perform: @escaping @MainActor (BranchRowSyncButtons) -> Void
    ) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: name) { [weak self] in
            guard let self else { return false }
            perform(self)
            return true
        }
    }
}

/// A capsule button drawn by hand, so its fill and text follow its look.
final class SyncPillButton: NSButton {
    enum Look {
        /// Outlined, on the list's colour.
        case plain
        /// Filled with the accent colour.
        case primary
        /// Outlined, with red text.
        case destructive
    }

    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// The shortcut glyph after the title: a size smaller and faded, as on the commit sheet.
    private static let shortcutFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let shortcutGap: CGFloat = 5
    private static let shortcutOpacity: CGFloat = 0.6
    private static let horizontalPadding: CGFloat = 10
    /// Room around a focusable button's capsule, so its focus ring isn't clipped.
    static let focusRingMargin: CGFloat = 4

    private let height: CGFloat
    private let focusMargin: CGFloat
    private let spinner = NSProgressIndicator(frame: .zero)
    private var isRunning = false

    /// The key this button's action answers to. Its width is always reserved, so the button
    /// keeps its size as the glyph comes and goes.
    var shortcut: String? {
        didSet {
            guard shortcut != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
            needsDisplay = true
        }
    }

    /// Whether the glyph is drawn: only on the button the key would press now.
    var showsKeyboardShortcut = false {
        didSet {
            if showsKeyboardShortcut != oldValue { needsDisplay = true }
        }
    }

    var look = Look.plain {
        didSet {
            guard look != oldValue else { return }
            // The spinner draws in its appearance's colours; a dark one is light enough for
            // the primary look's accent fill.
            spinner.appearance = look == .primary ? NSAppearance(named: .darkAqua) : nil
            needsDisplay = true
        }
    }

    init(title: String, height: CGFloat, focusMargin: CGFloat) {
        self.height = height
        self.focusMargin = focusMargin
        super.init(frame: .zero)
        self.title = title
        clipsToBounds = true
        isBordered = false
        setButtonType(.momentaryPushIn)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Sized with the title and any shortcut in place, so a running button keeps its width.
    override var intrinsicContentSize: NSSize {
        var width = ceil(NSAttributedString(string: title, attributes: [.font: Self.font]).size().width)
        if let shortcut {
            width += Self.shortcutGap + ceil(Self.shortcutString(shortcut, color: .labelColor).size().width)
        }
        return NSSize(
            width: width + Self.horizontalPadding * 2 + focusMargin * 2, height: height + focusMargin * 2)
    }

    private var capsule: NSBezierPath {
        let rect = bounds.insetBy(dx: focusMargin, dy: focusMargin)
        return NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    }

    override var focusRingMaskBounds: NSRect {
        bounds.insetBy(dx: focusMargin, dy: focusMargin)
    }

    override func drawFocusRingMask() {
        capsule.fill()
    }

    func apply(_ state: PickerButtonState, title: String) {
        if self.title != title {
            self.title = title
            invalidateIntrinsicContentSize()
        }
        isHidden = state == .hidden
        isEnabled = state == .enabled
        toolTip = if case let .disabled(reason) = state { reason } else { nil }
        isRunning = state == .running
        setAccessibilityLabel(isRunning ? "\(title), in progress" : title)
        updateSpinner()
        needsLayout = true
        needsDisplay = true
    }

    /// Spins only while running and on screen: a row removed mid-operation leaves the
    /// window once its fade ends, and its spinner must not keep going in the reuse queue.
    private func updateSpinner() {
        if isRunning, window != nil {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpinner()
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 16
        spinner.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        let (fill, text) = colors
        fill.setFill()
        capsule.fill()
        if look != .primary, isEnabled || isRunning {
            if isHighlighted {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                capsule.fill()
            }
            drawOutline()
        }
        guard !isRunning else { return }
        let string = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: text])
        let size = string.size()
        // Without the glyph, the title centres alone in the reserved width.
        guard showsKeyboardShortcut, let shortcut else {
            string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
            return
        }
        let glyph = Self.shortcutString(shortcut, color: text.withAlphaComponent(Self.shortcutOpacity))
        let glyphSize = glyph.size()
        let x = (bounds.width - size.width - Self.shortcutGap - glyphSize.width) / 2
        string.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
        glyph.draw(at: NSPoint(x: x + size.width + Self.shortcutGap, y: (bounds.height - glyphSize.height) / 2))
    }

    private static func shortcutString(_ shortcut: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: shortcut, attributes: [.font: shortcutFont, .foregroundColor: color])
    }

    /// Inset half a point so the 1pt line lands on whole pixels.
    private func drawOutline() {
        let rect = bounds.insetBy(dx: focusMargin + 0.5, dy: focusMargin + 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        path.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.15).setStroke()
        path.stroke()
    }

    /// Disabled is a faint grey capsule on every look. `draw` darkens a pressed outlined
    /// button, since its fill stays the list's colour.
    private var colors: (fill: NSColor, text: NSColor) {
        guard isEnabled || isRunning else {
            return (NSColor.labelColor.withAlphaComponent(0.05), .tertiaryLabelColor)
        }
        switch look {
        case .plain:
            return (.controlBackgroundColor, .labelColor)
        case .primary:
            let accent = NSColor.controlAccentColor
            return (isHighlighted ? accent.withSystemEffect(.pressed) : accent, .white)
        case .destructive:
            return (.controlBackgroundColor, .systemRed)
        }
    }
}

/// A Publish menu item's action, bound to its branch and remote when the menu is built.
private final class PublishChoice {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}
