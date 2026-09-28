import AppKit

/// A branch's Pull and Push buttons, Pull on the left, where Publish takes Push's place on
/// a branch that tracks nothing and Delete takes it on a branch whose upstream is gone.
/// Rows show them as pills on the highlighted row; the header shows the current branch's
/// as larger buttons with Push as the primary one. A running button keeps its place and
/// its width: the spinner replaces the title rather than the button. The callbacks carry
/// the branch these were configured for, never a row index, so a recycled cell cannot act
/// on another row.
final class BranchRowSyncButtons: NSView {
    enum Style {
        /// Row pills: neutral, or translucent white on the highlighted row's accent fill.
        case rowPills
        /// The header's buttons: Push filled with the accent colour.
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

    /// Row pills only: the row is highlighted, so the pills sit on the accent fill.
    var isOnAccent = false {
        didSet { if isOnAccent != oldValue { applyLooks() } }
    }

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
        clipsToBounds = true
        for button in buttons {
            // Row pills show only on the highlighted row: the search field keeps the
            // keyboard, and VoiceOver uses the row's custom actions. Header buttons take
            // focus for keyboard users. Neither has a key equivalent: Return belongs to
            // the highlighted row.
            button.refusesFirstResponder = !isHeader
            button.focusRingType = isHeader ? .default : .none
            button.target = self
            addSubview(button)
        }
        pullButton.action = #selector(pullClicked)
        pushButton.action = #selector(pushClicked)
        deleteButton.action = #selector(deleteClicked)
        applyLooks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var buttons: [SyncPillButton] { [pullButton, pushButton, deleteButton] }

    private func applyLooks() {
        switch style {
        case .rowPills:
            for button in buttons { button.look = isOnAccent ? .onAccent : .plain }
        case .header:
            pullButton.look = .plain
            pushButton.look = .primary
            deleteButton.look = .plain
        }
    }

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

/// A capsule button drawn by hand, so it reads on the accent fill of a highlighted row as
/// well as on the popover's background.
final class SyncPillButton: NSButton {
    enum Look {
        case plain
        /// Translucent white, for a highlighted row.
        case onAccent
        /// Filled with the accent colour.
        case primary
    }

    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let horizontalPadding: CGFloat = 10
    /// Room around a focusable button's capsule, so its focus ring isn't clipped.
    static let focusRingMargin: CGFloat = 4

    private let height: CGFloat
    private let focusMargin: CGFloat
    private let spinner = NSProgressIndicator(frame: .zero)
    private var isRunning = false

    var look = Look.plain {
        didSet {
            guard look != oldValue else { return }
            // The spinner draws in its appearance's colours; a dark one is light enough for
            // the accent fill.
            spinner.appearance = look == .plain ? nil : NSAppearance(named: .darkAqua)
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

    /// Sized with the title in place, so a running button keeps its width.
    override var intrinsicContentSize: NSSize {
        let width = ceil(NSAttributedString(string: title, attributes: [.font: Self.font]).size().width)
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
        guard !isRunning else { return }
        let string = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: text])
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    /// A disabled button fades on every look, so it still reads as disabled on the accent.
    private var colors: (fill: NSColor, text: NSColor) {
        let pressed = isHighlighted
        switch look {
        case .plain:
            guard isEnabled || isRunning else {
                return (NSColor.labelColor.withAlphaComponent(0.05), .tertiaryLabelColor)
            }
            return (NSColor.labelColor.withAlphaComponent(pressed ? 0.16 : 0.09), .labelColor)
        case .onAccent:
            guard isEnabled || isRunning else {
                return (NSColor.white.withAlphaComponent(0.1), NSColor.white.withAlphaComponent(0.45))
            }
            return (NSColor.white.withAlphaComponent(pressed ? 0.36 : 0.22), .white)
        case .primary:
            guard isEnabled || isRunning else {
                return (NSColor.labelColor.withAlphaComponent(0.05), .tertiaryLabelColor)
            }
            let accent = NSColor.controlAccentColor
            return (pressed ? accent.withSystemEffect(.pressed) : accent, .white)
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
