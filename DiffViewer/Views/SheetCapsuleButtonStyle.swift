import SwiftUI

/// Flat 32pt capsules for the sheet's buttons, a step below the title bar's 36pt controls. The
/// capsule itself is the click target, and hover and press feedback is skipped while disabled.
struct SheetCapsuleButtonStyle: ButtonStyle {
    enum Appearance {
        case tinted
        case neutral
        case prominent
    }

    let appearance: Appearance

    func makeBody(configuration: Configuration) -> some View {
        CapsuleBody(configuration: configuration, appearance: appearance)
    }

    private struct CapsuleBody: View {
        let configuration: ButtonStyleConfiguration
        let appearance: Appearance
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(labelStyle)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background { fill }
                // Disabled prominent buttons keep the accent fill at 40% opacity; the others fade.
                .opacity(isEnabled || appearance == .prominent ? 1 : 0.5)
                .contentShape(.capsule)
                .onHover { isHovered = $0 }
        }

        private var labelStyle: AnyShapeStyle {
            switch appearance {
            case .tinted: AnyShapeStyle(Color(nsColor: SheetCapsuleButtonPalette.tintedText))
            case .neutral: AnyShapeStyle(.primary)
            case .prominent: AnyShapeStyle(Self.textOnAccent)
            }
        }

        /// White, except on a light accent such as yellow, where white text is hard to read.
        /// The cut-off sits above macOS's blue, orange and green so those keep white text.
        private static var textOnAccent: Color {
            guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return .white }
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let luminance =
                0.2126 * linear(accent.redComponent) + 0.7152 * linear(accent.greenComponent)
                + 0.0722 * linear(accent.blueComponent)
            return luminance > 0.5 ? .black : .white
        }

        @ViewBuilder
        private var fill: some View {
            let pressed = isEnabled && configuration.isPressed
            let hovered = isEnabled && isHovered
            switch appearance {
            case .tinted:
                Capsule().fill(Color(nsColor: SheetCapsuleButtonPalette.tintedFill))
                    .overlay { Capsule().fill(Color.primary.opacity(pressed ? 0.1 : hovered ? 0.05 : 0)) }
            case .neutral:
                Capsule().fill(Color(nsColor: .tertiarySystemFill))
                    .overlay { Capsule().fill(Color.primary.opacity(pressed ? 0.1 : hovered ? 0.05 : 0)) }
            case .prominent:
                Capsule().fill(Color(nsColor: .controlAccentColor).opacity(isEnabled ? 1 : 0.4))
                    .overlay { Capsule().fill(Color.black.opacity(pressed ? 0.16 : hovered ? 0.08 : 0)) }
            }
        }
    }
}

/// Colours for the capsule buttons' tinted appearance.
private enum SheetCapsuleButtonPalette {
    static let tintedFill = DiffTheme.dynamic(light: rgb(241, 238, 255), dark: rgb(160, 140, 255, 0.2))
    static let tintedText = DiffTheme.dynamic(light: rgb(106, 76, 240), dark: rgb(200, 187, 255))

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
}
