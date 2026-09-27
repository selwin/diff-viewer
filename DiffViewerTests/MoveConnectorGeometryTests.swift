import CoreGraphics
import Testing

@testable import DiffViewer

struct MoveConnectorGeometryTests {
    private static let row: CGFloat = 20
    /// Ten rows tall.
    private static let viewport: CGFloat = 200
    private static let margin = MoveConnectorGeometry.clampRows * row

    private func band(
        _ left: Range<Int>, _ right: Range<Int>, leftClipMinY: CGFloat = 0, rightClipMinY: CGFloat = 0
    ) -> MoveConnectorBand? {
        MoveConnectorGeometry.band(
            left: left, right: right,
            in: MoveConnectorViewport(
                rowHeight: Self.row, leftClipMinY: leftClipMinY, rightClipMinY: rightClipMinY, height: Self.viewport))
    }

    @Test func bothEndsVisibleMapRowsIntoTheViewport() {
        let result = band(12..<14, 16..<18, leftClipMinY: 200, rightClipMinY: 200)
        #expect(result?.left == MoveConnectorBand.End(top: 40, bottom: 80))
        #expect(result?.right == MoveConnectorBand.End(top: 120, bottom: 160))
        #expect(result?.clampedSide == nil)
    }

    @Test func leftEndAboveTheViewportIsClampedPastTheTopEdge() {
        let result = band(2..<5, 14..<15, leftClipMinY: 200, rightClipMinY: 200)
        #expect(result?.clampedSide == .old)
        #expect(result?.left == MoveConnectorBand.End(top: -Self.margin - 60, bottom: -Self.margin))
        #expect(result?.right == MoveConnectorBand.End(top: 80, bottom: 100))
    }

    @Test func rightEndBelowTheViewportIsClampedPastTheBottomEdge() {
        let result = band(3..<5, 40..<42)
        #expect(result?.clampedSide == .new)
        #expect(result?.left == MoveConnectorBand.End(top: 60, bottom: 100))
        #expect(
            result?.right
                == MoveConnectorBand.End(top: Self.viewport + Self.margin, bottom: Self.viewport + Self.margin + 40))
    }

    @Test func neitherEndVisibleDrawsNothing() {
        #expect(band(0..<3, 4..<6, leftClipMinY: 400, rightClipMinY: 400) == nil)
        #expect(band(40..<43, 50..<52) == nil)
    }

    /// A band from above the viewport to below it has no row on screen to anchor it.
    @Test func endsOnOppositeSidesOfTheViewportDrawNothing() {
        #expect(band(0..<3, 30..<33, leftClipMinY: 200, rightClipMinY: 200) == nil)
        #expect(band(30..<33, 0..<3, leftClipMinY: 200, rightClipMinY: 200) == nil)
    }

    /// While one clip rubber-bands past the top, each end follows its own clip.
    @Test func eachEndFollowsItsOwnClipDuringOverscroll() {
        let result = band(1..<2, 3..<4, leftClipMinY: 0, rightClipMinY: -30)
        #expect(result?.left == MoveConnectorBand.End(top: 20, bottom: 40))
        #expect(result?.right == MoveConnectorBand.End(top: 90, bottom: 110))
    }

    /// Display rows, not document rows, place a changeset's ends: file headers and the
    /// spacer between files push the second file's rows down.
    @Test func changesetEndsAreShiftedByHeadersAndSeparators() {
        let displayRows: [DisplayRow] =
            [.fileHeader(section: 0)] + (0..<4).map { .documentRow($0) } + [
                .spacer(section: 1), .fileHeader(section: 1),
            ]
            + (4..<10).map { .documentRow($0) }
        let folded = FoldedRows(displayRows: displayRows, documentRowCount: 10, syntheticBoundaries: [0, 4, 4])
        let left = folded.displayRange(forDocumentRange: 5..<7)
        let right = folded.displayRange(forDocumentRange: 8..<10)
        #expect(left == 8..<10)
        #expect(right == 11..<13)
        let result = band(left, right, leftClipMinY: 100, rightClipMinY: 100)
        #expect(result?.left == MoveConnectorBand.End(top: 60, bottom: 100))
        #expect(result?.right == MoveConnectorBand.End(top: 120, bottom: 160))
    }

    @Test func candidateRowsCoverTheViewportAndTheClampMargin() {
        let rows = MoveConnectorGeometry.candidateRows(
            clipMinY: 210, viewportHeight: Self.viewport, rowHeight: Self.row)
        #expect(rows == 8..<23)
    }
}
