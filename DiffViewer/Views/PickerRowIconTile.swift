import AppKit

/// A picker row's round icon tile: a filled circle with a glyph centred in it. The circle
/// is drawn, so its dynamic colours follow the appearance.
final class PickerRowIconTile: NSView {
    /// What the tile shows, and in which colours.
    struct Glyph {
        enum Image {
            /// An asset, scaled to `side`.
            case asset(ImageResource, side: CGFloat)
            /// An SF Symbol, at its natural size for the point size and weight.
            case symbol(String, pointSize: CGFloat, weight: NSFont.Weight)
        }

        var image: Image
        var tint: NSColor
        var fill: NSColor

        /// The current branch, or the scope the diff shows: a bold checkmark on an accent tint.
        @MainActor static let current = Glyph(
            image: .symbol("checkmark", pointSize: 13, weight: .bold), tint: PickerStyle.accent,
            fill: PickerStyle.accentTint)
    }

    private let glyphView = NSImageView()
    private var glyphSize = NSSize.zero
    private var fill = NSColor.clear

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        glyphView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(glyphView)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ glyph: Glyph) {
        switch glyph.image {
        case let .asset(resource, side):
            glyphView.image = NSImage(resource: resource)
            glyphSize = NSSize(width: side, height: side)
        case let .symbol(name, pointSize, weight):
            glyphView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
            glyphSize = glyphView.image?.size ?? .zero
        }
        glyphView.contentTintColor = glyph.tint
        fill = glyph.fill
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        glyphView.frame = backingAlignedRect(
            NSRect(
                x: (bounds.width - glyphSize.width) / 2, y: (bounds.height - glyphSize.height) / 2,
                width: glyphSize.width, height: glyphSize.height),
            options: PickerViewGeometry.pixelAlignment)
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
