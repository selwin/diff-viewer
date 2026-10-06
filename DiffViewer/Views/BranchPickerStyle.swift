import AppKit

/// The branch picker's metrics, fonts and colours: a glass panel with raised white controls.
/// Colours are dynamic, so they follow the appearance and the accessibility display options
/// each time a view draws.
@MainActor
enum BranchPickerStyle {
    static let width: CGFloat = 368
    /// The list grows with its rows up to this height, then scrolls.
    static let maximumListHeight: CGFloat = 320
    /// What an empty list keeps room for: its message, or a spinner.
    static let minimumListHeight: CGFloat = 120
    static let rowHeight: CGFloat = 46
    static let sectionHeaderHeight: CGFloat = 30
    /// How far the row highlight stays from the panel's sides.
    static let highlightInset: CGFloat = 8
    /// The one edge everything lines up on: the title, segmented control, search field,
    /// section headers, row tiles and footer. Only the row highlight reaches past it.
    static let edgeInset: CGFloat = 22
    /// Row content sits this far inside the highlight, which puts the tile on `edgeInset`.
    static let contentInset: CGFloat = 14
    static let iconTileSize: CGFloat = 32
    static let highlightRadius: CGFloat = 20
    static let searchHeight: CGFloat = 34
    static let footerHeight: CGFloat = 38
    /// Between a row's name, its status and its pills.
    static let trailingGap: CGFloat = 8
    /// Room around a raised control's shape for its shadow.
    static let shadowMargin: CGFloat = 3

    // MARK: Fonts

    static let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
    static let headerStatusFont = NSFont.systemFont(ofSize: 12.5)
    static let nameFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    /// A search's matched characters, a step heavier than the name.
    static let matchFont = NSFont.systemFont(ofSize: 13.5, weight: .heavy)
    static let metaFont = NSFont.systemFont(ofSize: 12)
    static let sectionFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let pillFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let rowStatusFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    static let footerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    // MARK: Colours

    /// A raised control's fill in each state. Reduce Transparency swaps in opaque values:
    /// the same whites composited over #F7F7F9 (light) or #2A2A2C (dark).
    enum Raised {
        case rest
        case highlight
        case hover
        case pressed
    }

    static func raisedFill(_ state: Raised) -> NSColor {
        switch state {
        case .rest: raisedRest
        case .highlight: raisedHighlight
        case .hover: raisedHover
        case .pressed: raisedPressed
        }
    }

    private static let raisedRest = raised(light: 0.70, dark: 0.10, opaqueLight: 0xFDFDFD, opaqueDark: 0x3F3F41)
    private static let raisedHighlight = raised(
        light: 0.85, dark: 0.16, opaqueLight: 0xFEFEFE, opaqueDark: 0x4C4C4E)
    private static let raisedHover = raised(light: 1, dark: 0.20, opaqueLight: 0xFFFFFF, opaqueDark: 0x555556)
    /// Lighter than rest in light mode, so a press reads greyer on the light panel.
    private static let raisedPressed = raised(light: 0.55, dark: 0.26, opaqueLight: 0xFBFBFC, opaqueDark: 0x616163)

    /// A raised control's rim: faint, or the separator colour with Increase Contrast.
    static let raisedRim = NSColor(name: nil) { appearance in
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { return .separatorColor }
        return isDark(appearance) ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.06)
    }
    /// The lit top edge of a raised control.
    static let raisedSheen = dynamic(light: NSColor(white: 1, alpha: 0.9), dark: NSColor(white: 1, alpha: 0.10))
    static let raisedShadow = dynamic(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 0, alpha: 0.30))

    static let controlFill = dynamic(light: rgb(118, 118, 128, 0.12), dark: rgb(118, 118, 128, 0.24))
    static let tileFill = controlFill
    static let accent = dynamic(light: rgb(10, 122, 255), dark: rgb(10, 132, 255))
    static let accentTint = dynamic(light: rgb(10, 122, 255, 0.14), dark: rgb(10, 132, 255, 0.24))
    static let warning = dynamic(light: rgb(194, 94, 0), dark: rgb(255, 159, 10))
    static let meta = dynamic(light: rgb(60, 60, 67, 0.6), dark: rgb(235, 235, 245, 0.6))
    static let section = dynamic(light: rgb(60, 60, 67, 0.55), dark: rgb(235, 235, 245, 0.55))
    static let placeholder = dynamic(light: rgb(60, 60, 67, 0.45), dark: rgb(235, 235, 245, 0.3))

    // MARK: Drawing

    /// Fills `path` as a raised control: a soft shadow under it, a lit top edge and a rim.
    /// The view needs `shadowMargin` of room around the path for the shadow.
    static func drawRaised(_ path: NSBezierPath, fill: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = raisedShadow
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        fill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        // The outline moved down a point and clipped to the shape lights only its top.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let sheen = path.copy() as? NSBezierPath ?? path
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        sheen.transform(using: AffineTransform(translationByX: 0, byY: flipped ? 1 : -1))
        sheen.lineWidth = 1
        raisedSheen.setStroke()
        sheen.stroke()
        NSGraphicsContext.restoreGraphicsState()
        strokeRim(of: path)
    }

    /// A half-point line just inside `path`'s edge.
    static func strokeRim(of path: NSBezierPath, color: NSColor = raisedRim) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Helpers

    nonisolated private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    nonisolated private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { isDark($0) ? dark : light }
    }

    /// The provider runs each time the colour is drawn, so it reads the setting then.
    nonisolated private static func raised(light: CGFloat, dark: CGFloat, opaqueLight: Int, opaqueDark: Int) -> NSColor
    {
        NSColor(name: nil) { appearance in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                return hex(isDark(appearance) ? opaqueDark : opaqueLight)
            }
            return NSColor(white: 1, alpha: isDark(appearance) ? dark : light)
        }
    }

    nonisolated private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1)
        -> NSColor
    {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    nonisolated private static func hex(_ value: Int) -> NSColor {
        rgb(CGFloat(value >> 16 & 0xFF), CGFloat(value >> 8 & 0xFF), CGFloat(value & 0xFF))
    }
}
