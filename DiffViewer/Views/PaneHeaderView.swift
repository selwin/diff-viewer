import AppKit

/// The strip above a pane while find is open: the side's name, tinted when it is the side
/// being searched.
final class PaneHeaderView: NSView {
    static let height: CGFloat = 24
    private static let sidePadding: CGFloat = 8
    private static let gap: CGFloat = 4
    private static let accentBorder: CGFloat = 2

    private let magnifier = NSImageView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")

    private(set) var isSearched = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        for view in [magnifier, icon, title] { addSubview(view) }
        // One element, so VoiceOver reads the name and whether it is searched together.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(label: FindSideLabel, isSearched: Bool) {
        self.isSearched = isSearched
        title.stringValue = label.title
        icon.image = label.icon?.templateImage
        icon.isHidden = label.icon == nil
        magnifier.isHidden = !isSearched
        let color: NSColor = isSearched ? .labelColor : .secondaryLabelColor
        title.textColor = color
        icon.contentTintColor = color
        magnifier.contentTintColor = color
        setAccessibilityLabel(isSearched ? "\(label.title), searched" : label.title)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // Centred above the accent border, so the text sits the same in both states.
        let midY = (bounds.height - Self.accentBorder) / 2
        var x = Self.sidePadding
        for view in [magnifier, icon] where !view.isHidden {
            let size = view.image?.size ?? .zero
            view.frame = NSRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)
            x += size.width + Self.gap
        }
        let titleHeight = title.intrinsicContentSize.height
        title.frame = NSRect(
            x: x, y: midY - titleHeight / 2, width: max(0, bounds.width - x - Self.sidePadding), height: titleHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        if isSearched {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            bounds.fill(using: .sourceOver)
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: bounds.height - Self.accentBorder, width: bounds.width, height: Self.accentBorder).fill()
        } else {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill(using: .sourceOver)
        }
    }

    /// Redraw dynamic colours when the appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
