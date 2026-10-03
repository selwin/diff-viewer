import AppKit

/// The sentence over the branch picker's search field: "Switch to [branch]" or "Merge
/// [branch] into main". The token names the highlighted branch, or stands empty. When the
/// line runs short "into main" truncates first; the token keeps its width up to its cap.
final class BranchPickerInstructionView: NSView {
    static let height = BranchTokenView.height
    private static let font = NSFont.systemFont(ofSize: 12.5)
    private static let sideInset: CGFloat = 6
    /// Either side of the token.
    private static let tokenGap: CGFloat = 4

    private let verb = PickerLabel.make(font: font, color: .labelColor)
    private let token = BranchTokenView(frame: .zero)
    /// "into <target>", one label so it truncates as one.
    private let ending = PickerLabel.make(font: font, color: .labelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        ending.lineBreakMode = .byTruncatingTail
        for view in [verb, token, ending] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(_ instruction: BranchPickerInstruction) {
        verb.stringValue = instruction.verb
        token.name = instruction.token
        ending.isHidden = instruction.target == nil
        ending.stringValue = instruction.target.map { "into \($0)" } ?? ""
        let parts = [instruction.verb, instruction.token ?? "a branch", ending.stringValue]
        setAccessibilityValue(parts.filter { !$0.isEmpty }.joined(separator: " "))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let maxX = bounds.width - Self.sideInset
        var x = Self.sideInset
        x = place(verb, at: x, width: PickerViewGeometry.naturalSize(of: verb).width) + Self.tokenGap
        let tokenWidth = max(min(token.fittingWidth, maxX - x), 0)
        token.frame = NSRect(
            x: x, y: ((bounds.height - Self.height) / 2).rounded(), width: tokenWidth, height: Self.height)
        guard !ending.isHidden else { return }
        // The ending gives way before the token does.
        x = token.frame.maxX + Self.tokenGap
        place(ending, at: x, width: min(PickerViewGeometry.naturalSize(of: ending).width, max(maxX - x, 0)))
    }

    /// Centres `label` on the line at `x`, and returns where it ends.
    @discardableResult
    private func place(_ label: NSTextField, at x: CGFloat, width: CGFloat) -> CGFloat {
        let height = PickerViewGeometry.naturalSize(of: label).height
        label.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        return label.frame.maxX
    }
}

/// A branch name in a capsule. Empty, it is a dashed outline reading "a branch"; named, it
/// is tinted with the accent. Changes show at once, without animation.
final class BranchTokenView: NSView {
    static let height: CGFloat = 20
    private static let maximumWidth: CGFloat = 160
    private static let padding: CGFloat = 7
    private static let iconSize: CGFloat = 12
    private static let iconGap: CGFloat = 4

    var name: String? {
        didSet {
            guard name != oldValue else { return }
            applyState()
        }
    }

    private let icon = NSImageView()
    private let label = PickerLabel.make(font: .systemFont(ofSize: 12, weight: .medium), color: .tertiaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        icon.image = NSImage(resource: .gitBranch).withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingMiddle
        for view in [icon, label] { addSubview(view) }
        applyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The capsule's natural width, capped.
    var fittingWidth: CGFloat {
        let natural =
            Self.padding + Self.iconSize + Self.iconGap + PickerViewGeometry.naturalSize(of: label).width + Self.padding
        return min(natural.rounded(.up), Self.maximumWidth)
    }

    private func applyState() {
        label.stringValue = name ?? "a branch"
        let color: NSColor = name == nil ? .tertiaryLabelColor : .controlAccentColor
        label.textColor = color
        icon.contentTintColor = color
        needsDisplay = true
        needsLayout = true
        superview?.needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = 1
        if name == nil {
            path.setLineDash([3, 2], count: 2, phase: 0)
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        } else {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.4).setStroke()
        }
        path.stroke()
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(
            x: Self.padding, y: ((bounds.height - Self.iconSize) / 2).rounded(), width: Self.iconSize,
            height: Self.iconSize)
        let labelX = icon.frame.maxX + Self.iconGap
        let labelHeight = PickerViewGeometry.naturalSize(of: label).height
        label.frame = NSRect(
            x: labelX, y: ((bounds.height - labelHeight) / 2).rounded(),
            width: max(bounds.width - Self.padding - labelX, 0), height: labelHeight)
    }
}
