import CoreText
import Foundation
import Testing

@testable import DiffViewer

/// The count and controls sit at the row's right end; the label gets what is left.
struct SeparatorLayoutTests {
    private let rowRect = NSRect(x: 100, y: 40, width: 500, height: 20)

    private func layout(countWidth: CGFloat = 120, controls: [FoldControl]) -> SeparatorLayout {
        SeparatorLayout(
            rowRect: rowRect, gutterWidth: 40, textInset: 8, charWidth: 7, countWidth: countWidth, controls: controls)
    }

    @Test func countEndsAtTheTextInsetAndControlsEndBeforeIt() {
        let separator = layout(controls: [.expandDown, .expandUp])
        #expect(separator.countX + 120 == rowRect.maxX - 8)
        let rects = separator.controls.map(\.rect)
        #expect(separator.controls.map(\.control) == [.expandDown, .expandUp])
        #expect(rects[1].maxX + SeparatorLayout.countSpacing == separator.countX)
        #expect(rects[0].maxX + SeparatorLayout.controlSpacing == rects[1].minX)
    }

    @Test func labelRunsFromTextStartToTwoCharactersBeforeTheControls() {
        let separator = layout(controls: [.expandRun])
        #expect(separator.labelX == rowRect.minX + 40 + 8)
        #expect(separator.labelX + separator.labelWidth + 14 == separator.controls[0].rect.minX)
    }

    @Test func withoutControlsTheLabelStopsBeforeTheCount() {
        let separator = layout(controls: [])
        #expect(separator.labelX + separator.labelWidth + 14 == separator.countX)
    }

    @Test func labelHasNoRoomWhenTheCountFillsTheRow() {
        #expect(layout(countWidth: 440, controls: []).labelWidth <= 0)
    }

    @Test func narrowRowLaysOutLeftToRightFromTheTextStart() {
        let narrow = NSRect(x: 0, y: 0, width: 180, height: 20)
        let separator = SeparatorLayout(
            rowRect: narrow, gutterWidth: 40, textInset: 8, charWidth: 7, countWidth: 120,
            controls: [.expandDown, .expandUp])
        let textStart: CGFloat = 48
        let rects = separator.controls.map(\.rect)
        #expect(rects.allSatisfy { $0.minX >= textStart })
        #expect(rects[0].minX == textStart)
        #expect(rects[0].maxX + SeparatorLayout.controlSpacing == rects[1].minX)
        #expect(rects[1].maxX + SeparatorLayout.countSpacing == separator.countX)
        #expect(separator.countX + separator.countWidth == narrow.maxX - 8)
        #expect(separator.labelWidth <= 0)
    }

    @Test func controlsAreDroppedWhenTheRowCannotHoldThemAndTheCount() {
        // Text runs 48...92; two controls need 46 points before the count.
        let tooNarrow = NSRect(x: 0, y: 0, width: 100, height: 20)
        let separator = SeparatorLayout(
            rowRect: tooNarrow, gutterWidth: 40, textInset: 8, charWidth: 7, countWidth: 120,
            controls: [.expandDown, .expandUp])
        #expect(separator.controls.isEmpty)
        #expect(separator.countX == 48)
        #expect(separator.countWidth == 44)
        #expect(separator.labelWidth <= 0)
    }

    // MARK: - Copy icon

    private let tolerance: CGFloat = 0.001

    @Test func copyRectSitsOneSpacingAfterTheDrawnLabel() throws {
        let separator = layout(controls: [.expandRun])
        let rect = try #require(separator.copyRect(drawnLabelWidth: 50))
        #expect(abs(rect.minX - (separator.labelX + 50 + separator.copySpacing)) < tolerance)
    }

    @Test func copyRectIsNilWhenTheLabelOverflowsItsRoom() {
        let separator = layout(controls: [.expandRun])
        #expect(separator.copyRect(drawnLabelWidth: separator.availableLabelTextWidth + 100) == nil)
    }

    @Test func copyRectIsNilWithoutLabelRoom() {
        let narrow = NSRect(x: 0, y: 0, width: 180, height: 20)
        let separator = SeparatorLayout(
            rowRect: narrow, gutterWidth: 40, textInset: 8, charWidth: 7, countWidth: 120,
            controls: [.expandDown, .expandUp])
        #expect(separator.copyRect(drawnLabelWidth: 0) == nil)
    }

    @MainActor @Test func presentationIsNilWhenEvenTheEllipsisDoesNotFit() throws {
        // Leaves 3 points of label text room, less than an ellipsis.
        let separator = layout(countWidth: 404, controls: [])
        try #require(separator.availableLabelTextWidth > 0)
        let presentation = DiffPaneView.scopeLabelPresentation(
            names: ["Job", "_handle_retry_result"], layout: separator, font: DiffTheme.font(size: 12))
        #expect(presentation == nil)
    }

    /// UTF-16 length of the label shown for `names` with `textRoom` points of label text room.
    @MainActor private func shownLength(_ names: [String], textRoom: CGFloat) throws -> Int {
        let countWidth = layout(countWidth: 0, controls: []).availableLabelTextWidth - textRoom
        let presentation = try #require(
            DiffPaneView.scopeLabelPresentation(
                names: names, layout: layout(countWidth: countWidth, controls: []), font: DiffTheme.font(size: 12)))
        return CTLineGetStringRange(presentation.line).length
    }

    @MainActor @Test func presentationFallsBackToTheInnermostNameWhenTheChainDoesNotFit() throws {
        let names = ["Job", "_handle_retry_result"]
        #expect(try shownLength(names, textRoom: 280) == "Job › _handle_retry_result".utf16.count)
        // The innermost name fits in 170 points; the chain does not.
        #expect(try shownLength(names, textRoom: 170) == "_handle_retry_result".utf16.count)
    }

    @MainActor @Test func presentationMeasuresWideGlyphsShaped() throws {
        let font = DiffTheme.font(size: 12)
        let names = ["カート", "合計金額"]
        let chain = names.joined(separator: " › ")
        let shaped = CGFloat(
            CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(NSAttributedString(string: chain, attributes: [.font: font])), nil,
                nil, nil))
        let counted = CGFloat(chain.count) * ("0" as NSString).size(withAttributes: [.font: font]).width
        // Room enough by character count, too little once shaped.
        #expect(try shownLength(names, textRoom: (counted + shaped) / 2) == "合計金額".utf16.count)
    }

    @MainActor @Test func presentationPlacesTheIconWithinTheLabelRoom() throws {
        let separator = layout(controls: [.expandRun])
        let presentation = try #require(
            DiffPaneView.scopeLabelPresentation(
                names: ["Job", "_handle_retry_result"], layout: separator, font: DiffTheme.font(size: 12)))
        #expect(presentation.innermostName == "_handle_retry_result")
        #expect(presentation.copyRect.maxX <= separator.labelX + separator.labelWidth + tolerance)
    }
}
