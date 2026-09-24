import AppKit

/// A branch row's Pull and Push buttons, Push on the left, where Publish takes Push's
/// place on a branch that tracks nothing. A running button keeps its place and its
/// width: the spinner replaces the title rather than the button. The callbacks carry the
/// branch these were configured for, never a row index, so a recycled cell cannot act on
/// another row.
final class BranchRowSyncButtons: NSView {
    private static let gap: CGFloat = 6

    private let pullButton = NSButton(title: "Pull", target: nil, action: nil)
    private let pushButton = NSButton(title: "Push", target: nil, action: nil)
    private let pullSpinner = NSProgressIndicator(frame: .zero)
    private let pushSpinner = NSProgressIndicator(frame: .zero)
    /// Measured with the title in place, so a running button keeps its width while its
    /// title is blank.
    private var pullSize = NSSize.zero
    private var pushSize = NSSize.zero
    private var states = RowSyncButtons.hidden
    private var onPull: () -> Void = {}
    private var onPush: () -> Void = {}
    private var onPublish: (String) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        for (button, indicator) in [(pullButton, pullSpinner), (pushButton, pushSpinner)] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            // The table keeps the keyboard; VoiceOver reaches these through the row's
            // custom actions. No key equivalent: Return belongs to the highlighted row.
            button.refusesFirstResponder = true
            button.target = self
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isDisplayedWhenStopped = false
            indicator.sizeToFit()
            indicator.frame.size = NSSize(width: 16, height: 16)
            button.addSubview(indicator)
            addSubview(button)
        }
        pullButton.bezelColor = .controlAccentColor
        pullButton.action = #selector(pullClicked)
        pushButton.action = #selector(pushClicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func pullClicked() { onPull() }
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
    /// Shows the buttons while `isRevealed` or while one of them runs, and hides the view
    /// when neither has anything to show. `onPublish` takes the branch, then the remote.
    func configure(
        _ buttons: RowSyncButtons, isRevealed: Bool, branch: String, onPull: @escaping (String) -> Void,
        onPush: @escaping (String) -> Void, onPublish: @escaping (String, String) -> Void
    ) {
        states = buttons
        self.onPull = { onPull(branch) }
        self.onPush = { onPush(branch) }
        self.onPublish = { onPublish(branch, $0) }
        pullSize = apply(buttons.pull, to: pullButton, indicator: pullSpinner, title: "Pull")
        pushSize = apply(buttons.push, to: pushButton, indicator: pushSpinner, title: buttons.pushTitle)
        let isRunning = buttons.pull == .running || buttons.push == .running
        isHidden = !(isRevealed || isRunning) || (buttons.pull == .hidden && buttons.push == .hidden)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    // swiftlint:enable function_parameter_count

    /// Returns the button's size with its title in place.
    private func apply(
        _ state: PickerButtonState, to button: NSButton, indicator: NSProgressIndicator, title: String
    ) -> NSSize {
        button.title = title
        button.sizeToFit()
        let size = button.frame.size
        button.isHidden = state == .hidden
        button.title = state == .running ? "" : title
        button.isEnabled = state == .enabled
        button.toolTip = if case let .disabled(reason) = state { reason } else { nil }
        button.setAccessibilityLabel(state == .running ? "\(title), in progress" : title)
        if state == .running {
            indicator.startAnimation(nil)
        } else {
            indicator.stopAnimation(nil)
        }
        indicator.isHidden = state != .running
        return size
    }

    override var intrinsicContentSize: NSSize {
        let sizes = [(pushButton, pushSize), (pullButton, pullSize)].filter { !$0.0.isHidden }.map(\.1)
        let width = sizes.map(\.width).reduce(0, +) + Self.gap * CGFloat(max(sizes.count - 1, 0))
        return NSSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (button, size) in [(pushButton, pushSize), (pullButton, pullSize)] where !button.isHidden {
            button.frame = NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + Self.gap
        }
        for (button, indicator) in [(pullButton, pullSpinner), (pushButton, pushSpinner)] where !indicator.isHidden {
            indicator.frame.origin = NSPoint(
                x: (button.bounds.width - indicator.frame.width) / 2,
                y: (button.bounds.height - indicator.frame.height) / 2)
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
