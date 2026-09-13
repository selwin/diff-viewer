import Foundation
import Testing
@testable import DiffViewer

struct RowFoldingTests {
    private let options = FoldOptions(contextLines: 5, expansionStep: 20, minimumHiddenRun: 4)

    private func fold(_ blocks: [Range<Int>], rows: Int, state: FoldState = FoldState(), options: FoldOptions? = nil)
        -> FoldedRows
    {
        RowFolding.fold(changeBlocks: blocks, documentRowCount: rows, state: state, options: options ?? self.options)
    }

    /// Collapses runs of `.documentRow` into ranges for compact assertions.
    private func shape(_ folded: FoldedRows) -> [String] {
        var out: [String] = []
        var run: Range<Int>?
        func flush() { if let r = run { out.append("rows \(r.lowerBound)..<\(r.upperBound)"); run = nil } }
        for row in folded.displayRows {
            switch row {
            case let .documentRow(i):
                if let r = run, r.upperBound == i { run = r.lowerBound..<(i + 1) } else { flush(); run = i..<(i + 1) }
            case let .separator(hidden):
                flush(); out.append("sep \(hidden.lowerBound)..<\(hidden.upperBound)")
            }
        }
        flush()
        return out
    }

    // MARK: Folding

    @Test func noChangeBlocksShowsAllRows() {
        let folded = fold([], rows: 10)
        #expect(shape(folded) == ["rows 0..<10"])
        #expect(folded.displayRows.count == folded.documentRowCount)
    }

    @Test func contextSurroundsBlockWithSeparatorsAtBothEnds() {
        let folded = fold([50..<52], rows: 100)
        #expect(shape(folded) == ["sep 0..<45", "rows 45..<57", "sep 57..<100"])
    }

    @Test func blockAtFileStartHasNoLeadingSeparator() {
        #expect(shape(fold([0..<3], rows: 100)) == ["rows 0..<8", "sep 8..<100"])
    }

    @Test func blockAtFileEndHasNoTrailingSeparator() {
        #expect(shape(fold([97..<100], rows: 100)) == ["sep 0..<92", "rows 92..<100"])
    }

    @Test func adjacentHunksMergeWhenGapWithinContext() {
        // Gap of 10 rows == 2 * context: fully covered, no separator between.
        #expect(shape(fold([20..<21, 31..<32], rows: 100)) == ["sep 0..<15", "rows 15..<37", "sep 37..<100"])
        // Gap of 11 rows leaves one hidden row, below the minimum run, so it is shown.
        #expect(shape(fold([20..<21, 32..<33], rows: 100)) == ["sep 0..<15", "rows 15..<38", "sep 38..<100"])
    }

    @Test func smallGapsAreShownNotFolded() {
        // Hidden gap of exactly minimumHiddenRun (4) folds; 3 does not.
        #expect(
            shape(fold([20..<21, 35..<36], rows: 100)) == [
                "sep 0..<15", "rows 15..<26", "sep 26..<30", "rows 30..<41", "sep 41..<100",
            ])
        #expect(shape(fold([20..<21, 34..<35], rows: 100)) == ["sep 0..<15", "rows 15..<40", "sep 40..<100"])
    }

    @Test func zeroContextKeepsOnlyChangedRows() {
        let zero = FoldOptions(contextLines: 0, expansionStep: 20, minimumHiddenRun: 4)
        #expect(shape(fold([50..<52], rows: 100, options: zero)) == ["sep 0..<50", "rows 50..<52", "sep 52..<100"])
    }

    @Test func expandDownRevealsFirstStep() {
        var state = FoldState()
        state.expandDown(57..<100, step: 20)
        #expect(shape(fold([50..<52], rows: 100, state: state)) == ["sep 0..<45", "rows 45..<77", "sep 77..<100"])
    }

    @Test func expandUpRevealsLastStep() {
        var state = FoldState()
        state.expandUp(0..<45, step: 20)
        #expect(shape(fold([50..<52], rows: 100, state: state)) == ["sep 0..<25", "rows 25..<57", "sep 57..<100"])
    }

    @Test func expandRunRemovesSeparator() {
        var state = FoldState()
        state.expandRun(0..<45)
        #expect(shape(fold([50..<52], rows: 100, state: state)) == ["rows 0..<57", "sep 57..<100"])
    }

    @Test func expandAllYieldsIdentity() {
        var state = FoldState()
        state.expandAll(documentRowCount: 100)
        let folded = fold([50..<52], rows: 100, state: state)
        #expect(shape(folded) == ["rows 0..<100"])
        #expect(folded.displayRows.count == folded.documentRowCount)
    }

    @Test func residualBelowMinimumAutoReveals() {
        // Hidden run of 22: one step of 20 leaves 2, which is shown rather than folded.
        var state = FoldState()
        state.expandDown(57..<79, step: 20)
        #expect(
            shape(fold([50..<52, 84..<85], rows: 100, state: state)) == ["sep 0..<45", "rows 45..<90", "sep 90..<100"])
    }

    @Test func stepsClampToTheRun() {
        var state = FoldState()
        state.expandDown(10..<15, step: 20)
        state.expandUp(30..<35, step: 20)
        #expect(state.revealedDocumentRows == IndexSet(integersIn: 10..<15).union(IndexSet(integersIn: 30..<35)))
    }

    @Test func revealedRowsOutsideDocumentAreIgnored() {
        var state = FoldState()
        state.expandRun(90..<500)
        #expect(
            shape(fold([50..<52], rows: 100, state: state)) == [
                "sep 0..<45", "rows 45..<57", "sep 57..<90", "rows 90..<100",
            ])
    }

    @Test func controlsDependOnRunSizeAndPosition() {
        #expect(RowFolding.controls(for: 0..<20, documentRowCount: 100, options: options) == [.expandRun])
        #expect(RowFolding.controls(for: 0..<45, documentRowCount: 100, options: options) == [.expandUp])
        #expect(RowFolding.controls(for: 57..<100, documentRowCount: 100, options: options) == [.expandDown])
        #expect(RowFolding.controls(for: 30..<60, documentRowCount: 100, options: options) == [.expandUp, .expandDown])
    }

    @Test func invariantsHoldForRandomBlockSets() {
        var generator = SplitMix64(seed: 7)
        for _ in 0..<200 {
            let rows = Int.random(in: 0..<400, using: &generator)
            var blocks: [Range<Int>] = []
            var cursor = Int.random(in: 0..<20, using: &generator)
            while cursor < rows {
                let length = Int.random(in: 1...6, using: &generator)
                let end = min(rows, cursor + length)
                blocks.append(cursor..<end)
                cursor = end + Int.random(in: 1..<40, using: &generator)
            }
            var state = FoldState()
            if Bool.random(using: &generator), let block = blocks.first {
                state.expandDown(block.upperBound..<rows, step: 20)
            }
            let context = Int.random(in: 0...8, using: &generator)
            let opts = FoldOptions(contextLines: context, expansionStep: 20, minimumHiddenRun: 4)
            let folded = RowFolding.fold(changeBlocks: blocks, documentRowCount: rows, state: state, options: opts)

            // Exact cover, in order.
            var covered = 0
            for (index, row) in folded.displayRows.enumerated() {
                switch row {
                case let .documentRow(i):
                    #expect(i == covered)
                    #expect(folded.displayIndex(forDocumentRow: i) == index)
                    covered = i + 1
                case let .separator(hidden):
                    #expect(hidden.lowerBound == covered)
                    #expect(hidden.count >= 4)
                    for i in hidden { #expect(folded.displayIndex(forDocumentRow: i) == index) }
                    // Separators cover only equal rows: no change block intersects.
                    for block in blocks { #expect(block.overlaps(hidden) == false) }
                    covered = hidden.upperBound
                }
            }
            #expect(covered == rows)
            // Every changed row is visible, as is its context.
            for block in blocks {
                let visible = folded.displayRange(forDocumentRange: block)
                #expect(visible.count == block.count)
            }
        }
    }

    @Test func foldingALargeDocumentIsFast() {
        let rows = 20_000
        let blocks = stride(from: 0, to: rows, by: 200).map { $0..<($0 + 1) }
        var state = FoldState()
        state.expandDown(1..<195, step: 20)
        let start = ContinuousClock.now
        let folded = fold(blocks, rows: rows, state: state)
        #expect(ContinuousClock.now - start < .milliseconds(50))
        #expect(folded.displayRows.count < rows)
        #expect(folded.displayIndex(forDocumentRow: rows - 1) == folded.displayRows.count - 1)
    }

    // MARK: Mapping

    @Test func displayIndexMapsHiddenRowsToSeparator() {
        let folded = fold([50..<52], rows: 100)
        #expect(folded.displayIndex(forDocumentRow: 0) == 0)
        #expect(folded.displayIndex(forDocumentRow: 44) == 0)
        #expect(folded.displayIndex(forDocumentRow: 45) == 1)
        #expect(folded.displayIndex(forDocumentRow: 56) == 12)
        #expect(folded.displayIndex(forDocumentRow: 99) == 13)
        #expect(folded.documentRow(forDisplayIndex: 0) == 0)
        #expect(folded.documentRow(forDisplayIndex: 1) == 45)
        #expect(folded.documentRow(forDisplayIndex: 13) == 57)
    }

    @Test func displayRangeForChangeBlockIsExact() {
        let folded = fold([50..<52], rows: 100)
        #expect(folded.displayRange(forDocumentRange: 50..<52) == 6..<8)
        // A document range spanning hidden rows collapses onto the separator.
        #expect(folded.displayRange(forDocumentRange: 0..<45) == 0..<1)
        #expect(folded.displayRange(forDocumentRange: 40..<47) == 0..<3)
    }

    @Test func documentRangeForDisplayRangeCoversHiddenRuns() {
        let folded = fold([50..<52], rows: 100)
        #expect(folded.documentRange(forDisplayRange: 0..<1) == 0..<45)
        #expect(folded.documentRange(forDisplayRange: 1..<3) == 45..<47)
        #expect(folded.documentRange(forDisplayRange: 12..<14) == 56..<100)
    }

    @Test func rangesEndingOnSeparatorMapToItsUpperBound() {
        let folded = fold([50..<52], rows: 100)
        #expect(folded.documentRange(forDisplayRange: 10..<14) == 54..<100)
        #expect(folded.documentRange(forDisplayRange: 0..<14) == 0..<100)
    }

    @Test func emptyRangesStayEmpty() {
        let folded = fold([50..<52], rows: 100)
        #expect(folded.displayRange(forDocumentRange: 10..<10).isEmpty)
        #expect(folded.displayRange(forDocumentRange: 100..<100) == 14..<14)
        #expect(folded.documentRange(forDisplayRange: 3..<3).isEmpty)
        #expect(folded.documentRange(forDisplayRange: 14..<14) == 100..<100)
    }

    @Test func endOfDocumentRangesDoNotOverrun() {
        let folded = fold([97..<100], rows: 100)
        #expect(folded.displayRows.count == 9)
        #expect(folded.displayRange(forDocumentRange: 90..<100) == 0..<9)
        #expect(folded.documentRange(forDisplayRange: 8..<9) == 99..<100)
        #expect(folded.documentRange(forDisplayRange: 0..<9) == 0..<100)
    }

    @Test func emptyDocumentProducesEmptyProjection() {
        let folded = fold([], rows: 0)
        #expect(folded.displayRows.isEmpty)
        #expect(folded.documentRowCount == 0)
        #expect(folded.displayRange(forDocumentRange: 0..<0) == 0..<0)
        #expect(folded.documentRange(forDisplayRange: 0..<0) == 0..<0)
        let identity = FoldedRows.identity(documentRowCount: 0)
        #expect(identity.displayRows.isEmpty)
    }

    @Test func identityIsPassThrough() {
        let folded = FoldedRows.identity(documentRowCount: 5)
        #expect(shape(folded) == ["rows 0..<5"])
        #expect(folded.displayIndex(forDocumentRow: 3) == 3)
        #expect(folded.documentRange(forDisplayRange: 1..<4) == 1..<4)
    }

    // MARK: Options

    @Test func contextLinesAreClampedFromDefaults() {
        #expect(FoldOptions.validated(contextLines: nil).contextLines == 5)
        #expect(FoldOptions.validated(contextLines: -3).contextLines == 0)
        #expect(FoldOptions.validated(contextLines: 12).contextLines == 12)
        #expect(FoldOptions.validated(contextLines: Int.max).contextLines == 200)
    }
}
