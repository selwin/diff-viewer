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

    /// Names measured at seven points a character, as a plain monospaced font would.
    private func monospaced(_ names: [String]) -> CGFloat {
        CGFloat(names.joined(separator: " › ").count) * 7
    }

    @Test func labelShowsBothNamesWhenTheyFit() {
        // "Cart › total" is 12 characters.
        #expect(
            SeparatorLayout.labelNames(["Cart", "total"], availableWidth: 84, width: monospaced) == ["Cart", "total"])
    }

    @Test func labelFallsBackToTheInnermostNameWhenBothDoNotFit() {
        #expect(SeparatorLayout.labelNames(["Cart", "total"], availableWidth: 83, width: monospaced) == ["total"])
    }

    @Test func labelKeepsTheInnermostNameEvenWhenItAloneDoesNotFit() {
        // The caller truncates it at the tail.
        #expect(SeparatorLayout.labelNames(["Cart", "total"], availableWidth: 10, width: monospaced) == ["total"])
    }

    @Test func labelDecisionUsesTheShapedWidthOfWideGlyphs() {
        let font = DiffTheme.font(size: 12)
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let names = ["カート", "合計金額"]
        func shaped(_ names: [String]) -> CGFloat {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: names.joined(separator: " › "), attributes: [.font: font]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let counted = CGFloat(names.joined(separator: " › ").count) * charWidth
        // Wide enough by character count, too narrow once shaped.
        #expect(shaped(names) > counted)
        let between = (counted + shaped(names)) / 2
        #expect(SeparatorLayout.labelNames(names, availableWidth: between, width: shaped) == ["合計金額"])
        #expect(SeparatorLayout.labelNames(names, availableWidth: shaped(names), width: shaped) == names)
    }
}
