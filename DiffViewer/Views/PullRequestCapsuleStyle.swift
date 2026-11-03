import AppKit

/// The pull request capsule's colours per state, from GitHub's Primer palette so a state
/// reads as it does on GitHub: the content colour, the tint behind it at rest, and the
/// solid fill under the pointer, which carries white content.
@MainActor
enum PullRequestCapsuleStyle {
    struct Colors {
        let foreground: NSColor
        let tint: NSColor
        let hoverFill: NSColor
    }

    static let hoverForeground = NSColor.white

    static func colors(for state: ListedPullRequest.State) -> Colors {
        switch state {
        case .open: open
        case .draft: draft
        case .merged: merged
        case .closed: closed
        }
    }

    private static let open = make(
        light: 0x1A7F37, lightTint: 0.13, dark: 0x3FB950, darkTint: 0.18, darkHover: 0x238636)
    private static let draft = make(
        light: 0x59636E, lightTint: 0.14, dark: 0x9198A1, darkTint: 0.18, darkHover: 0x656C76)
    private static let merged = make(
        light: 0x8250DF, lightTint: 0.13, dark: 0xA371F7, darkTint: 0.18, darkHover: 0x8957E5)
    private static let closed = make(
        light: 0xCF222E, lightTint: 0.11, dark: 0xF85149, darkTint: 0.16, darkHover: 0xDA3633)

    /// The tint is the foreground at the given opacity. In light mode the hover fill is the
    /// foreground itself; dark mode's is a deeper shade, so white content stays legible.
    private static func make(light: Int, lightTint: CGFloat, dark: Int, darkTint: CGFloat, darkHover: Int) -> Colors {
        Colors(
            foreground: PickerStyle.dynamic(light: color(light), dark: color(dark)),
            tint: PickerStyle.dynamic(light: color(light, lightTint), dark: color(dark, darkTint)),
            hoverFill: PickerStyle.dynamic(light: color(light), dark: color(darkHover)))
    }

    private static func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        PickerStyle.rgb(CGFloat(hex >> 16 & 0xFF), CGFloat(hex >> 8 & 0xFF), CGFloat(hex & 0xFF), alpha)
    }
}
