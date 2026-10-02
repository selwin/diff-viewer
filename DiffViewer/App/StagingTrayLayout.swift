import CoreGraphics

/// How tall the staging tray's list is. The tray's header and commit button never
/// compress, and the Changes list above keeps a floor, so the staged list is what gives.
enum StagingTrayLayout {
    /// A directory caption's header row, the same at every sidebar size.
    static let captionHeight: CGFloat = 19
    /// The space a sidebar list puts above each section header after the first.
    static let sectionGap: CGFloat = 13
    /// The space above the first section header; the list adds none.
    static let firstHeaderGap: CGFloat = 0
    /// The space a sidebar list leaves below its last row.
    static let bottomPadding: CGFloat = 10
    /// Today's five 38pt rows; past it the list scrolls.
    static let maxListHeight: CGFloat = 190
    /// The tray's header, commit button and padding.
    static let trayChrome: CGFloat = 76
    /// Extra top padding while the staging capsule sits on the tray's edge, so the capsule's
    /// lower half does not cover the header.
    static let capsuleClearance: CGFloat = 12
    static let changesFloor: CGFloat = 120

    /// The staged list's full height: a caption per directory and `rowHeight` per file,
    /// with the list's own gaps and padding. Nothing at all when nothing is staged.
    static func contentHeight(groupCount: Int, rowCount: Int, rowHeight: CGFloat) -> CGFloat {
        guard groupCount > 0 else { return 0 }
        return firstHeaderGap + CGFloat(groupCount) * captionHeight + CGFloat(groupCount - 1) * sectionGap
            + CGFloat(rowCount) * rowHeight + bottomPadding
    }

    /// The staged list's height: its content up to `maxListHeight`, less when the sidebar
    /// is short, and none once not even the minimum fits. The minimum is a viewport with
    /// room for a caption and one row; a list holding the selection keeps it and Changes
    /// gives way instead. It does not promise the selected row is the one in view.
    static func listHeight(
        contentHeight: CGFloat, rowHeight: CGFloat, sidebarHeight: CGFloat, holdsSelection: Bool, hasCapsule: Bool
    ) -> CGFloat {
        let wanted = min(contentHeight, maxListHeight)
        let chrome = trayChrome + (hasCapsule ? capsuleClearance : 0)
        let room = sidebarHeight - chrome - changesFloor
        let height = min(wanted, room)
        let minimum = min(wanted, firstHeaderGap + captionHeight + rowHeight)
        guard height < minimum else { return height }
        return holdsSelection ? minimum : 0
    }

    /// Whether the list scrolls, which the tray marks with a fade at its foot.
    static func overflows(contentHeight: CGFloat, listHeight: CGFloat) -> Bool {
        contentHeight > listHeight
    }
}
