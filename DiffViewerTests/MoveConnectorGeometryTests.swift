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

    private func pills(_ rows: [(Range<Int>, Range<Int>)]) -> [MoveConnectorPill] {
        let bands = rows.enumerated().compactMap { index, rows in
            band(rows.0, rows.1, leftClipMinY: 200, rightClipMinY: 200).map { (index: index, band: $0) }
        }
        return MoveConnectorGeometry.pills(for: bands, width: 24, viewportHeight: Self.viewport)
    }

    @Test func clampedBandsGetAPillTopAlignedWithTheirVisibleEnd() {
        // Band 0 is clamped on the new side, band 1 on the old side, band 2 is fully visible.
        let result = pills([(12..<13, 30..<32), (2..<5, 14..<15), (16..<17, 18..<19)])
        #expect(result.map(\.index) == [0, 1])
        let height = MoveConnectorGeometry.pillHeight
        #expect(result[0].rect == CGRect(x: 2, y: 40, width: 20, height: height))
        #expect(result[1].rect == CGRect(x: 2, y: 80, width: 20, height: height))
    }

    @Test func pillStaysAtTheTopInsetThenRidesUpWithTheBlock() {
        let height = MoveConnectorGeometry.pillHeight
        // The block's top is above the viewport and its bottom is at 80.
        #expect(pills([(2..<5, 8..<14)]).first?.rect.minY == MoveConnectorGeometry.pillInset)
        // Only 20pt of the block is left on screen, shorter than the pill.
        #expect(pills([(2..<5, 9..<11)]).first?.rect.minY == 20 - height)
    }

    @Test func overlappingPillsAreSeparatedByTheGap() {
        // Adjacent blocks at 80 and 100: the second moves below the first.
        let result = pills([(2..<3, 14..<15), (3..<4, 15..<16)])
        let first = result[0].rect
        #expect(first.minY == 80)
        #expect(result[1].rect.minY == first.maxY + MoveConnectorGeometry.pillGap)
    }

    @Test func pillsPushedPastTheBottomAreDropped() {
        // Blocks at 140, 160 and 180: the third is pushed to 196 and would end past the inset.
        let result = pills([(2..<3, 17..<18), (3..<4, 18..<19), (4..<5, 19..<20)])
        #expect(result.map(\.index) == [0, 1])
        #expect(result[1].rect.minY == 168)
    }

    @Test func pillLabelsAbbreviateLargeNumbersRoundingDown() {
        let labels = [9999, 10000, 24410, 123_456, 1_234_567].map(MoveConnectorGeometry.pillLabel(forLineNumber:))
        #expect(labels == ["9999", "10k", "24k", "123k", "1M"])
    }
}
