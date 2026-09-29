import AppKit

/// The grey "+120 −45" a repository's tab shows while its working tree has changes.
final class TabChurnView: NSView {
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalTo: stack.heightAnchor),
        ])
        // Ask AppKit to shrink the title before the counts. A tab too narrow for both
        // still clips them.
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ churn: RepositoryChurn) {
        let parts = churn.tabParts
        if parts != stack.arrangedSubviews.compactMap({ ($0 as? NSTextField)?.stringValue }) {
            for view in stack.arrangedSubviews { view.removeFromSuperview() }
            for part in parts { stack.addArrangedSubview(Self.label(part)) }
        }
        toolTip = churn.summary
        setAccessibilityLabel(churn.summary)
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        // Proportional letters with fixed-width digits, so a count ticking up doesn't jiggle.
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        // Secondary, not tertiary: the tab bar's selected-tab styling washed tertiary out on
        // the selected tab and on tabs selected before.
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityElement(false)
        return label
    }
}
