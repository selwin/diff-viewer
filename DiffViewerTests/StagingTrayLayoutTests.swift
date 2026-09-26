import CoreGraphics
import Testing

@testable import DiffViewer

struct StagingTrayLayoutTests {
    private static let row = StagingTrayLayout.rowHeight
    /// Room for every row the tray ever shows, above the chrome and the Changes floor.
    private static let tall: CGFloat = 900

    @Test func threeRowsShowInFull() {
        #expect(
            StagingTrayLayout.listHeight(rowCount: 3, sidebarHeight: Self.tall, holdsSelection: false) == 3 * Self.row)
    }

    @Test func twelveRowsAreCappedAtFive() {
        #expect(
            StagingTrayLayout.listHeight(rowCount: 12, sidebarHeight: Self.tall, holdsSelection: false) == 5 * Self.row)
    }

    /// Changes keeps its floor; the staged list takes what is left.
    @Test func aShortSidebarClampsTheListAboveTheChangesFloor() {
        let sidebar = StagingTrayLayout.trayChrome + StagingTrayLayout.changesFloor + 100
        #expect(StagingTrayLayout.listHeight(rowCount: 5, sidebarHeight: sidebar, holdsSelection: false) == 100)
    }

    /// Too short for one row, the list goes, unless it holds the selection: then one row
    /// stays and Changes gives way.
    @Test func tooShortForOneRowShowsNoneWithoutTheSelectionAndOneWithIt() {
        let sidebar = StagingTrayLayout.trayChrome + StagingTrayLayout.changesFloor + 20
        #expect(StagingTrayLayout.listHeight(rowCount: 5, sidebarHeight: sidebar, holdsSelection: false) == 0)
        #expect(StagingTrayLayout.listHeight(rowCount: 5, sidebarHeight: sidebar, holdsSelection: true) == Self.row)
    }
}
