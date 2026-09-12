import AppKit

/// Colors and metrics for the diff panes. All colors are dynamic (light/dark aware).
enum DiffTheme {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    static let background = NSColor.textBackgroundColor
    static let text = NSColor.textColor
    static let lineNumber = NSColor.tertiaryLabelColor
    static let lineNumberChanged = NSColor.secondaryLabelColor
    static let divider = NSColor.separatorColor

    static let gutterBackground = dynamic(light: rgb(246, 248, 250), dark: rgb(30, 32, 36))

    static let deletedRow = dynamic(light: rgb(255, 235, 233), dark: rgb(248, 81, 73, 0.16))
    static let deletedToken = dynamic(light: rgb(255, 129, 130, 0.45), dark: rgb(248, 81, 73, 0.42))
    static let deletedGutter = dynamic(light: rgb(255, 206, 203), dark: rgb(248, 81, 73, 0.30))

    static let addedRow = dynamic(light: rgb(218, 251, 225), dark: rgb(46, 160, 67, 0.16))
    static let addedToken = dynamic(light: rgb(74, 194, 107, 0.45), dark: rgb(46, 160, 67, 0.42))
    static let addedGutter = dynamic(light: rgb(172, 238, 187), dark: rgb(46, 160, 67, 0.30))

    static let padBackground = dynamic(light: rgb(246, 248, 250), dark: rgb(28, 30, 34))
    static let padStripe = dynamic(light: rgb(0, 0, 0, 0.06), dark: rgb(255, 255, 255, 0.05))

    static let tabWidth = 4

    static func font(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
