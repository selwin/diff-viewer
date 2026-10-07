import AppKit

/// A branch's Pull and Push buttons, Pull on the left, where Publish takes Push's place on
/// a branch that tracks nothing and Delete takes it on a branch whose upstream is gone.
/// Rows show them as neutral pills on the highlighted row; the header shows the current
/// branch's as raised capsules. Pull takes the accent text when it shows, since a
/// diverged branch must pull before it can push; otherwise Push does. A running
/// button keeps its place and its width: the spinner replaces the title rather than the
/// button. The callbacks carry
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

    /// Whether the buttons keep room for their shortcut glyphs; a crowded row gives it up.
    var reservesShortcutWidth = true {
        didSet {
            guard reservesShortcutWidth != oldValue else { return }
            for button in buttons { button.reservesShortcutWidth = reservesShortcutWidth }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(style: Style) {
        self.style = style
        let isHeader = style == .header
        let height: CGFloat = isHeader ? 34 : 24
        let margin: CGFloat = isHeader ? SyncPillButton.focusRingMargin : 0
        let surface: SyncPillButton.Surface = isHeader ? .raised : .neutral
        gap = isHeader ? 8 - margin * 2 : 6
        func button(_ title: String) -> SyncPillButton {
            SyncPillButton(title: title, height: height, focusMargin: margin, surface: surface)
        }
        pullButton = button("Pull")
        pushButton = button("Push")
        deleteButton = button("Delete…")
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

    /// Redraws with the current accessibility display options.
    func refreshRendering() {
        for button in buttons { button.refreshRendering() }
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
        // Rows keep their pills neutral; only the header's primary button is blue.
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
        let height = visibleButtons.map(\.intrinsicContentSize.height).max() ?? 0
        return NSSize(width: width(reservingShortcuts: reservesShortcutWidth), height: height)
    }

    /// The width with or without the shortcuts' room, whichever `reservesShortcutWidth`
    /// picks, so a row can choose before it commits.
    func width(reservingShortcuts: Bool) -> CGFloat {
        let widths = visibleButtons.map { $0.width(reservingShortcut: reservingShortcuts) }
        return widths.reduce(0, +) + gap * CGFloat(max(widths.count - 1, 0))
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

/// A capsule button drawn by hand, so its fill and text follow its surface and look.
final class SyncPillButton: NSButton {
    /// What the capsule is drawn as.
    enum Surface {
        /// A quiet grey fill, for row pills.
        case neutral
        /// A raised white capsule with a hover fill, for the header.
        case raised
    }

    /// The title's colour.
    enum Look {
        case plain
        /// Accent text.
        case primary
        /// Red text.
        case destructive
    }

    private static let font = PickerStyle.pillFont
    /// The shortcut glyph after the title: a size smaller and faded, as on the commit sheet.
    private static let shortcutFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let shortcutGap: CGFloat = 5
    private static let shortcutOpacity: CGFloat = 0.6
    /// Room around a focusable button's capsule, so its focus ring isn't clipped.
    static let focusRingMargin: CGFloat = 4

    private let height: CGFloat
    private let focusMargin: CGFloat
    private let surface: Surface
    private let horizontalPadding: CGFloat
    private let spinner = NSProgressIndicator(frame: .zero)
    private var isRunning = false
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    /// The key this button's action answers to. Its width is reserved while
    /// `reservesShortcutWidth` is set, so the button keeps its size as the glyph comes and
    /// goes.
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

    /// Off, the shortcut's room is given up and its glyph is never drawn.
    var reservesShortcutWidth = true {
        didSet {
            guard reservesShortcutWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var look = Look.plain {
        didSet { if look != oldValue { needsDisplay = true } }
    }

    init(title: String, height: CGFloat, focusMargin: CGFloat, surface: Surface) {
        self.height = height
        self.focusMargin = focusMargin
        self.surface = surface
        horizontalPadding = surface == .raised ? 14 : 10
        super.init(frame: .zero)
        self.title = title
        clipsToBounds = true
        isBordered = false
        setButtonType(.momentaryPushIn)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        if surface == .raised {
            // `.activeAlways`: a scripted launch never makes the popover key.
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                    userInfo: nil))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Sized with the title in place, so a running button keeps its width.
    override var intrinsicContentSize: NSSize {
        NSSize(width: width(reservingShortcut: reservesShortcutWidth), height: height + focusMargin * 2)
    }

    /// The frame's width with or without the shortcut's room.
    func width(reservingShortcut: Bool) -> CGFloat {
        var width = ceil(NSAttributedString(string: title, attributes: [.font: Self.font]).size().width)
        if reservingShortcut, let shortcut {
            width += Self.shortcutGap + ceil(Self.shortcutString(shortcut, color: .labelColor).size().width)
        }
        return width + horizontalPadding * 2 + focusMargin * 2
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A hidden button gets no exit event.
    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
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
        let isActive = isEnabled || isRunning
        switch surface {
        case .raised:
            let state: PickerStyle.Raised =
                !isActive ? .rest : isHighlighted ? .pressed : isHovered ? .hover : .rest
            PickerStyle.drawRaised(capsule, fill: PickerStyle.raisedFill(state))
        case .neutral:
            (isActive ? PickerStyle.controlFill : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
            capsule.fill()
            if isActive, isHighlighted {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                capsule.fill()
            }
        }
        let text = textColor
        guard !isRunning else { return }
        let string = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: text])
        let size = string.size()
        // Without the glyph, the title centres alone in the reserved width.
        guard showsKeyboardShortcut, reservesShortcutWidth, let shortcut else {
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

    private var textColor: NSColor {
        guard isEnabled || isRunning else { return .tertiaryLabelColor }
        switch look {
        case .plain: return .labelColor
        case .primary: return PickerStyle.accent
        case .destructive: return .systemRed
        }
    }

    /// Redraws with the current accessibility display options.
    func refreshRendering() {
        needsDisplay = true
    }
}

/// A Publish menu item's action, bound to its branch and remote when the menu is built.
private final class PublishChoice {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}
