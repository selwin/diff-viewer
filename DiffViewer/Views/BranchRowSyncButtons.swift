import AppKit

/// A branch row's Pull and Push buttons, Push on the left. A running button keeps its
/// place and its width: the spinner replaces the title rather than the button. The
/// callbacks carry the branch these were configured for, never a row index, so a
/// recycled cell cannot act on another row.
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
    @objc private func pushClicked() { onPush() }

    /// Shows the buttons while `isRevealed` or while one of them runs, and hides the view
    /// when neither has anything to show.
    func configure(
        _ buttons: RowSyncButtons, isRevealed: Bool, branch: String, onPull: @escaping (String) -> Void,
        onPush: @escaping (String) -> Void
    ) {
        states = buttons
        self.onPull = { onPull(branch) }
        self.onPush = { onPush(branch) }
        pullSize = apply(buttons.pull, to: pullButton, indicator: pullSpinner, title: "Pull")
        pushSize = apply(buttons.push, to: pushButton, indicator: pushSpinner, title: buttons.pushTitle)
        let isRunning = buttons.pull == .running || buttons.push == .running
        isHidden = !(isRevealed || isRunning) || (buttons.pull == .hidden && buttons.push == .hidden)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

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
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions: [NSAccessibilityCustomAction] = []
        if states.pull == .enabled {
            actions.append(
                NSAccessibilityCustomAction(name: "Pull") { [weak self] in
                    self?.onPull()
                    return self != nil
                })
        }
        if states.push == .enabled {
            actions.append(
                NSAccessibilityCustomAction(name: states.pushTitle) { [weak self] in
                    self?.onPush()
                    return self != nil
                })
        }
        return actions
    }
}
