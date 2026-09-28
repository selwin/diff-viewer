import AppKit

/// What stands in for an empty list: a message, with a spinner while it loads.
final class PickerEmptyStateView: NSView {
    private let spinner = NSProgressIndicator()
    private let label = PickerLabel.make(
        font: .systemFont(ofSize: 13), color: .secondaryLabelColor, alignment: .center)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [spinner, label] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// A nil text hides the view.
    func configure(text: String?, isLoading: Bool) {
        isHidden = text == nil
        label.stringValue = text ?? ""
        if isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !isLoading
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let labelSize = PickerViewGeometry.naturalSize(of: label)
        let spinnerWidth: CGFloat = spinner.isHidden ? 0 : 16 + 6
        let top = ((bounds.height - labelSize.height) / 2).rounded()
        let lineX = ((bounds.width - spinnerWidth - labelSize.width) / 2).rounded()
        if !spinner.isHidden {
            spinner.frame = NSRect(x: lineX, y: top + ((labelSize.height - 16) / 2).rounded(), width: 16, height: 16)
        }
        label.frame = NSRect(x: lineX + spinnerWidth, y: top, width: labelSize.width, height: labelSize.height)
    }
}
