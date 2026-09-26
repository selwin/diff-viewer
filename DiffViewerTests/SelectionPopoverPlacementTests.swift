import CoreGraphics
import Testing

@testable import DiffViewer

struct SelectionPopoverPlacementTests {
    /// The List's viewport inside a 900 × 398 overlay: the sidebar ends at x = 228 and the
    /// rows show between y = 10 and y = 390.
    private static let list = CGRect(x: 0, y: 10, width: 228, height: 380)
    private static let container = CGSize(width: 900, height: 398)
    private static let popover = CGSize(width: 223, height: 90)
    private static let panelX: CGFloat = 238
    private static let topPinY: CGFloat = 18
    private static let bottomPinY: CGFloat = 292

    private static func row(y: CGFloat) -> CGRect {
        CGRect(x: 16, y: y, width: 195, height: 18)
    }

    private static func place(
        rowFrame: CGRect?, index: Int = 10, mounted: ClosedRange<Int>? = 5...20,
        container: CGSize = container
    ) -> SelectionPopoverPlacement? {
        SelectionPopoverPlacement.place(
            rowFrame: rowFrame, selectedRowIndex: index, mountedIndexRange: mounted, visibleListFrame: list,
            containerSize: container, popoverSize: popover)
    }

    /// The arrow's tip lands inside the row, in the overlay's coordinates.
    private static func arrowTouches(_ row: CGRect, _ placement: SelectionPopoverPlacement) -> Bool {
        guard let arrowY = placement.arrowY else { return false }
        return (row.minY...row.maxY).contains(placement.origin.y + arrowY)
    }

    // MARK: Visible rows

    @Test func aRowInTheMiddleGetsThePanelBesideItWithTheArrowOnItsMiddle() throws {
        let row = Self.row(y: 150)
        let placement = try #require(Self.place(rowFrame: row))
        #expect(placement.origin.x == Self.panelX)
        #expect(placement.origin.y + (placement.arrowY ?? 0) == row.midY)
        #expect(placement.origin.y < row.minY)
    }

    @Test func aRowNearTheBottomKeepsThePanelInsideAndTheArrowOnTheRow() throws {
        let row = Self.row(y: 330)
        let placement = try #require(Self.place(rowFrame: row))
        #expect(placement.origin.y + Self.popover.height == Self.container.height - SelectionPopoverPlacement.margin)
        #expect(Self.arrowTouches(row, placement))
    }

    /// The last row sits a few points above the list's bottom edge, as the List pads it.
    @Test func theArrowStaysOnTheStraightEdgeForTheLastRow() throws {
        let row = Self.row(y: 365)
        let placement = try #require(Self.place(rowFrame: row))
        let arrowY = try #require(placement.arrowY)
        #expect(arrowY == Self.popover.height - SelectionPopoverPlacement.arrowInset)
        #expect(Self.arrowTouches(row, placement))
    }

    /// Half past the edge, the row's middle is still in the list but beyond the arrow's
    /// reach, so the panel keeps to the edge without pointing at the next row over.
    @Test func aHalfHiddenRowBeyondTheArrowsReachGetsNoArrow() throws {
        let bottom = try #require(Self.place(rowFrame: Self.row(y: 379)))
        #expect(bottom.origin.y == Self.bottomPinY + SelectionPopoverPlacement.margin)
        #expect(bottom.arrowY == nil)
        let top = try #require(Self.place(rowFrame: Self.row(y: 2)))
        #expect(top.origin.y == SelectionPopoverPlacement.margin)
        #expect(top.arrowY == nil)
    }

    // MARK: Rows out of sight

    @Test func aRowScrolledAboveTheListPinsThePanelToTheTopWithoutAnArrow() throws {
        let placement = try #require(Self.place(rowFrame: Self.row(y: -120)))
        #expect(placement.origin == CGPoint(x: Self.panelX, y: Self.topPinY))
        #expect(placement.arrowY == nil)
    }

    @Test func aRowScrolledBelowTheListPinsThePanelToTheBottomWithoutAnArrow() throws {
        let placement = try #require(Self.place(rowFrame: Self.row(y: 600)))
        #expect(placement.origin == CGPoint(x: Self.panelX, y: Self.bottomPinY))
        #expect(placement.arrowY == nil)
    }

    /// A built row just past an edge has its frame, which says which edge; the index
    /// would not, since it sits inside the mounted range.
    @Test func aMountedRowJustPastAnEdgeIsPinnedByItsFrame() throws {
        let aboveTop = try #require(Self.place(rowFrame: Self.row(y: 0), index: 10))
        #expect(aboveTop.origin.y == Self.topPinY)
        #expect(aboveTop.arrowY == nil)
        let belowBottom = try #require(Self.place(rowFrame: Self.row(y: 382), index: 10))
        #expect(belowBottom.origin.y == Self.bottomPinY)
        #expect(belowBottom.arrowY == nil)
    }

    @Test func anUnmountedRowIsPinnedByItsIndexAgainstTheMountedRange() throws {
        let above = try #require(Self.place(rowFrame: nil, index: 2, mounted: 5...20))
        #expect(above.origin.y == Self.topPinY)
        #expect(above.arrowY == nil)
        let below = try #require(Self.place(rowFrame: nil, index: 25, mounted: 5...20))
        #expect(below.origin.y == Self.bottomPinY)
        #expect(below.arrowY == nil)
    }

    @Test func anUnmeasuredRowWithNoKnownDirectionHidesThePanel() {
        #expect(Self.place(rowFrame: nil, index: 10, mounted: 5...20) == nil)
        #expect(Self.place(rowFrame: nil, index: 10, mounted: nil) == nil)
    }

    // MARK: Stored frames

    /// During a fast selection change the store can still hold the previous row's frame;
    /// pointing at it would point at the wrong row.
    @Test func aFrameStoredByAnotherRowCountsAsUnmeasured() {
        let stored = Self.row(y: 150)
        let frame = SelectionPopoverPlacement.rowFrame(
            stored, measuredFor: "unstaged:old.txt", firstSelectedID: "unstaged:new.txt")
        #expect(frame == nil)
        #expect(Self.place(rowFrame: frame, index: 10, mounted: 5...20) == nil)
        #expect(
            SelectionPopoverPlacement.rowFrame(
                stored, measuredFor: "unstaged:old.txt", firstSelectedID: "unstaged:old.txt") == stored)
    }

    @Test func theMountedRangeSpansTheLowestAndHighestBuiltRows() {
        let rows = ["a", "b", "c", "d", "e"]
        #expect(SelectionPopoverPlacement.mountedIndexRange(of: ["d", "b"], in: rows) == 1...3)
        #expect(SelectionPopoverPlacement.mountedIndexRange(of: ["gone"], in: rows) == nil)
    }

    // MARK: Narrow windows

    @Test func aNarrowWindowPullsThePanelOverTheSidebarAndDropsTheArrow() throws {
        let narrow = CGSize(width: 400, height: 398)
        let placement = try #require(Self.place(rowFrame: Self.row(y: 150), container: narrow))
        #expect(placement.origin.x == narrow.width - Self.popover.width - SelectionPopoverPlacement.margin)
        #expect(placement.arrowY == nil)
        let tiny = CGSize(width: 150, height: 398)
        let squeezed = try #require(Self.place(rowFrame: Self.row(y: 150), container: tiny))
        #expect(squeezed.origin.x == SelectionPopoverPlacement.margin)
    }
}
