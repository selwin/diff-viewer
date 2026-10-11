import AppKit

/// Text field colours shared by the sheets that take typed input.
enum SheetFieldPalette {
    static let fieldFill = DiffTheme.dynamic(light: .textBackgroundColor, dark: NSColor(white: 0, alpha: 0.25))
    static let fieldBorder = DiffTheme.dynamic(
        light: NSColor(white: 0, alpha: 0.15), dark: NSColor(white: 1, alpha: 0.14))
}
