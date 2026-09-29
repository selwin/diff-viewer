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

    // MARK: Rows

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
    /// Between the header and the search field.
    static let searchTopGap: CGFloat = 8
    static let searchHeight: CGFloat = 28
    /// Tighter than `searchTopGap`, so the first group sits close under the search field.
    static let listTopGap: CGFloat = 5
    /// What an empty list keeps room for: its message, or a spinner.
    static let emptyListHeight: CGFloat = 120

    /// The popover's header: a title over a detail line.
    @MainActor
    enum Header {
        static let topPadding: CGFloat = 13
        static let sidePadding: CGFloat = 16
        static let bottomPadding: CGFloat = 4
        /// Between the title and the detail line.
        static let lineGap: CGFloat = 2
        static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        static let detailFont = NSFont.systemFont(ofSize: 12)
    }
}
