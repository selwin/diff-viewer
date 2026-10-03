import CoreGraphics

/// How tall the staging tray's list is. The tray's header and commit button never
/// compress, and the Changes list above keeps a floor, so the staged list is what gives.
/// It grows past its default cap into space Changes does not need.
enum StagingTrayLayout {
    /// A directory caption's header row, the same at every sidebar size.
    static let captionHeight: CGFloat = 19
    /// The space a sidebar list puts above each section header after the first.
    static let sectionGap: CGFloat = 13
    /// The space above the first section header; the list adds none.
    static let firstHeaderGap: CGFloat = 0
    /// The space a sidebar list leaves below its last row.
    static let bottomPadding: CGFloat = 10
    /// The staged list's default cap when Changes needs the remaining space.
    static let defaultListHeightCap: CGFloat = 190
    /// Room below the Changes list's last row so it can scroll clear of the staging capsule.
    static let changesCapsulePadding: CGFloat = 64
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

    // swiftlint:disable function_parameter_count
    /// Uses spare space below Changes, with the default cap when Changes needs the room.
    /// Short sidebars hide the list below its minimum, a caption and one row, unless it
    /// holds the selection; then Changes gives way. The selected row may still be out of view.
    /// `changesContentHeight` includes content, top inset and capsule padding; `.infinity`
    /// keeps the default cap until measured.
    static func listHeight(
        contentHeight: CGFloat, rowHeight: CGFloat, changesContentHeight: CGFloat, sidebarHeight: CGFloat,
        holdsSelection: Bool, hasCapsule: Bool
    ) -> CGFloat {
        let chrome = trayChrome + (hasCapsule ? capsuleClearance : 0)
        let requiredChangesHeight = max(changesFloor, changesContentHeight)
        let availableStagedHeight = sidebarHeight - chrome - requiredChangesHeight
        let wanted = min(contentHeight, max(defaultListHeightCap, availableStagedHeight))
        let room = sidebarHeight - chrome - changesFloor
        let height = min(wanted, room)
        let minimum = min(wanted, firstHeaderGap + captionHeight + rowHeight)
        guard height < minimum else { return height }
        return holdsSelection ? minimum : 0
    }
    // swiftlint:enable function_parameter_count

    /// Whether the list scrolls, which the tray marks with a fade at its foot.
    static func overflows(contentHeight: CGFloat, listHeight: CGFloat) -> Bool {
        contentHeight > listHeight
    }
}
