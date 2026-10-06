import AppKit

/// Geometry and fonts shared by the title bar's pickers.
@MainActor
enum PickerMetrics {
    static let width: CGFloat = 410
    /// The popover grows with its list up to this height, then the list scrolls.
    static let maximumHeight: CGFloat = 560
    /// How far the row highlight stays from the popover's sides.
    static let rowInset: CGFloat = 8
    /// Text and icons sit this far inside the highlight.
    static let contentInset: CGFloat = 10
    static let rowHeight: CGFloat = 44
    static let headerRowHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 7

    /// The popover's surface, opaque so the glass behind it doesn't grey the header.
    static let popoverBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.165, green: 0.165, blue: 0.173, alpha: 1)
            : NSColor(srgbRed: 0.969, green: 0.969, blue: 0.976, alpha: 1)
    }
    /// Below the header, a shade lighter than `popoverBackground`.
    static let listBackground = NSColor.controlBackgroundColor

    // MARK: Rows

    /// The row highlight: the neutral fill macOS uses for hover, not the accent, which means selection.
    static let highlightColor = NSColor.labelColor.withAlphaComponent(0.08)
    /// The highlight while a row is pressed.
    static let pressedHighlightColor = NSColor.labelColor.withAlphaComponent(0.14)

    static let nameFont = NSFont.systemFont(ofSize: 13)
    static let currentNameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let subtitleFont = NSFont.systemFont(ofSize: 11)
    static let statusFont = NSFont.systemFont(ofSize: 12)
    /// Between a row's name and its subtitle.
    static let lineGap: CGFloat = 1
    /// Between the name, the status, and the row's buttons.
    static let trailingGap: CGFloat = 10

    // MARK: Search and list

    /// How far the search field's background stays from the popover's sides.
    static let searchInset: CGFloat = 12
    /// Between the header's hairline and the search field.
    static let searchTopGap: CGFloat = searchInset
    static let searchHeight: CGFloat = 28
    /// Tighter than `searchTopGap`, so the first group sits close under the search field.
    static let listTopGap: CGFloat = 5
    /// What an empty list keeps room for: its message, or a spinner.
    static let emptyListHeight: CGFloat = 120

    /// The popover's header: a title over a subtitle, with a hairline below.
    @MainActor
    enum Header {
        static let topPadding: CGFloat = 16
        /// Above the hairline.
        static let bottomPadding: CGFloat = 14
        /// Lines the title up with the rows' icons and text below.
        static let sidePadding: CGFloat = rowInset + contentInset
        static let dividerHeight: CGFloat = 1
        /// Between the title and the subtitle.
        static let titleSubtitleGap: CGFloat = 2
        /// Between the text block and the trailing accessory.
        static let trailingGap: CGFloat = 8
        /// Between the title's text and its accessory, whose hover fill already pads the icon.
        static let titleAccessoryGap: CGFloat = 2
        static let titleFont = NSFont.systemFont(ofSize: 18, weight: .bold)
        static let subtitleFont = NSFont.systemFont(ofSize: 12)
    }
}
