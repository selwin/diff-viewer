import SwiftUI

/// The colour for text and icons drawn on the accent colour.
enum AccentForeground {
    /// White, except on a light accent such as yellow, where white text is hard to read.
    /// The cut-off sits above macOS's blue, orange and green so those keep white text.
    static var color: Color {
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return .white }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance =
            0.2126 * linear(accent.redComponent) + 0.7152 * linear(accent.greenComponent)
            + 0.0722 * linear(accent.blueComponent)
        return luminance > 0.5 ? .black : .white
    }
}
