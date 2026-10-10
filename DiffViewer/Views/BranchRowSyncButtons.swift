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
    let pullButton: PickerPillButton
    let pushButton: PickerPillButton
    private let deleteButton: PickerPillButton
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
        let margin: CGFloat = isHeader ? PickerPillButton.focusRingMargin : 0
        let surface: PickerPillButton.Surface = isHeader ? .raised : .neutral
        gap = isHeader ? 8 - margin * 2 : 6
        func button(_ title: String) -> PickerPillButton {
            PickerPillButton(title: title, height: height, focusMargin: margin, surface: surface)
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

    private var buttons: [PickerPillButton] { [pullButton, pushButton, deleteButton] }

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

    private func canPress(_ button: PickerPillButton, state: PickerButtonState) -> Bool {
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

    private var visibleButtons: [PickerPillButton] {
        buttons.filter { !$0.isHidden }
    }

    /// The header's buttons carry margins for their focus rings; the visible shapes exclude them.
    override var alignmentRectInsets: NSEdgeInsets {
        let margin = style == .header ? PickerPillButton.focusRingMargin : 0
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

/// A Publish menu item's action, bound to its branch and remote when the menu is built.
private final class PublishChoice {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}
