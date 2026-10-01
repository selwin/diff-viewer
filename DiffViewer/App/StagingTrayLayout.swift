import CoreGraphics

/// How tall the staging tray's list is. The tray's header and commit button never
/// compress, and the Changes list above keeps a floor, so the staged list is what gives.
enum StagingTrayLayout {
    static let rowHeight: CGFloat = 38
    static let maxVisibleRows = 5
    /// The tray's header, commit button and padding.
    static let trayChrome: CGFloat = 76
    /// Extra top padding while the staging capsule sits on the tray's edge, so the capsule's
    /// lower half does not cover the header.
    static let capsuleClearance: CGFloat = 12
    static let changesFloor: CGFloat = 120

    /// The staged list's height: up to five rows, less when the sidebar is short, and none
    /// once not even one row fits. A list holding the selection always keeps one row, and
    /// Changes gives way instead, so the selected row is never hidden.
    static func listHeight(rowCount: Int, sidebarHeight: CGFloat, holdsSelection: Bool, hasCapsule: Bool) -> CGFloat {
        let wanted = CGFloat(min(rowCount, maxVisibleRows)) * rowHeight
        let chrome = trayChrome + (hasCapsule ? capsuleClearance : 0)
        let room = sidebarHeight - chrome - changesFloor
        let height = min(wanted, room)
        let floor = holdsSelection ? min(wanted, rowHeight) : 0
        return height < rowHeight ? floor : height
    }
}
