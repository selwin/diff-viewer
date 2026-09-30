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
            case .fileHeader, .spacer, .notice:
                flush(); out.append("synthetic")  // Only a changeset projection emits these.
            }
        }
        flush()
        return out
    }

    // MARK: Folding

    struct ShapeCase: CustomTestStringConvertible {
        let name: String
        let blocks: [Range<Int>]
        let rows: Int
        var contextLines = 5
        let shape: [String]
        /// Nothing is folded, so every document row is its own display row.
        var showsEveryRow = false

        var testDescription: String { name }
    }

    static let shapeCases: [ShapeCase] = [
        ShapeCase(
            name: "no change blocks shows all rows", blocks: [], rows: 10, shape: ["rows 0..<10"],
            showsEveryRow: true),
        ShapeCase(
            name: "context surrounds a block with separators at both ends", blocks: [50..<52], rows: 100,
            shape: ["sep 0..<45", "rows 45..<57", "sep 57..<100"]),
        ShapeCase(
            name: "block at file start has no leading separator", blocks: [0..<3], rows: 100,
            shape: ["rows 0..<8", "sep 8..<100"]),
        ShapeCase(
            name: "block at file end has no trailing separator", blocks: [97..<100], rows: 100,
            shape: ["sep 0..<92", "rows 92..<100"]),
        // A gap of 10 rows is 2 * context: fully covered, no separator between.
        ShapeCase(
            name: "hunks merge when the gap is within context", blocks: [20..<21, 31..<32], rows: 100,
            shape: ["sep 0..<15", "rows 15..<37", "sep 37..<100"]),
        // A gap of 11 rows leaves one hidden row, below the minimum run, so it is shown.
        ShapeCase(
            name: "hunks merge when one row is left hidden", blocks: [20..<21, 32..<33], rows: 100,
            shape: ["sep 0..<15", "rows 15..<38", "sep 38..<100"]),
        ShapeCase(
            name: "a hidden gap of exactly the minimum run folds", blocks: [20..<21, 35..<36], rows: 100,
            shape: ["sep 0..<15", "rows 15..<26", "sep 26..<30", "rows 30..<41", "sep 41..<100"]),
        ShapeCase(
            name: "a hidden gap below the minimum run is shown", blocks: [20..<21, 34..<35], rows: 100,
            shape: ["sep 0..<15", "rows 15..<40", "sep 40..<100"]),
        ShapeCase(
            name: "zero context keeps only changed rows", blocks: [50..<52], rows: 100, contextLines: 0,
            shape: ["sep 0..<50", "rows 50..<52", "sep 52..<100"]),
    ]

    @Test(arguments: shapeCases) func foldingKeepsChangesAndContext(_ testCase: ShapeCase) {
        let options = FoldOptions(contextLines: testCase.contextLines, expansionStep: 20, minimumHiddenRun: 4)
        let folded = fold(testCase.blocks, rows: testCase.rows, options: options)
        #expect(shape(folded) == testCase.shape)
        if testCase.showsEveryRow { #expect(folded.displayRows.count == folded.documentRowCount) }
    }

    /// One user reveal, applied to a 100-row document.
    enum Reveal {
        case down(Range<Int>)
        case up(Range<Int>)
        case run(Range<Int>)
        case all

        func apply(to state: inout FoldState, step: Int) {
            switch self {
            case let .down(hidden): state.expandDown(hidden, step: step)
            case let .up(hidden): state.expandUp(hidden, step: step)
            case let .run(hidden): state.expandRun(hidden)
            case .all: state.expandAll(documentRowCount: 100)
            }
        }
    }

    struct ExpansionCase: CustomTestStringConvertible {
        let name: String
        let blocks: [Range<Int>]
        let reveal: Reveal
        let shape: [String]
        var showsEveryRow = false

        var testDescription: String { name }
    }

    static let expansionCases: [ExpansionCase] = [
        ExpansionCase(
            name: "expand down reveals the first step", blocks: [50..<52], reveal: .down(57..<100),
            shape: ["sep 0..<45", "rows 45..<77", "sep 77..<100"]),
        ExpansionCase(
            name: "expand up reveals the last step", blocks: [50..<52], reveal: .up(0..<45),
            shape: ["sep 0..<25", "rows 25..<57", "sep 57..<100"]),
        ExpansionCase(
            name: "expanding a run removes its separator", blocks: [50..<52], reveal: .run(0..<45),
            shape: ["rows 0..<57", "sep 57..<100"]),
        ExpansionCase(
            name: "expanding everything is the identity", blocks: [50..<52], reveal: .all,
            shape: ["rows 0..<100"], showsEveryRow: true),
        // A hidden run of 22: one step of 20 leaves 2, which is shown rather than folded.
        ExpansionCase(
            name: "a residual below the minimum is revealed", blocks: [50..<52, 84..<85], reveal: .down(57..<79),
            shape: ["sep 0..<45", "rows 45..<90", "sep 90..<100"]),
        ExpansionCase(
            name: "revealed rows outside the document are ignored", blocks: [50..<52], reveal: .run(90..<500),
            shape: ["sep 0..<45", "rows 45..<57", "sep 57..<90", "rows 90..<100"]),
    ]

    @Test(arguments: expansionCases) func revealedRowsJoinTheVisibleOnes(_ testCase: ExpansionCase) {
        var state = FoldState()
        testCase.reveal.apply(to: &state, step: 20)
        let folded = fold(testCase.blocks, rows: 100, state: state)
        #expect(shape(folded) == testCase.shape)
        if testCase.showsEveryRow { #expect(folded.displayRows.count == folded.documentRowCount) }
    }

    @Test func stepsClampToTheRun() {
        var state = FoldState()
        state.expandDown(10..<15, step: 20)
        state.expandUp(30..<35, step: 20)
        #expect(state.revealedDocumentRows == IndexSet(integersIn: 10..<15).union(IndexSet(integersIn: 30..<35)))
    }

    @Test func controlsDependOnRunSizeAndPosition() {
        #expect(RowFolding.controls(for: 0..<20, documentRowCount: 100, options: options) == [.expandRun])
        #expect(RowFolding.controls(for: 0..<45, documentRowCount: 100, options: options) == [.expandUp])
        #expect(RowFolding.controls(for: 57..<100, documentRowCount: 100, options: options) == [.expandDown])
        #expect(RowFolding.controls(for: 30..<60, documentRowCount: 100, options: options) == [.expandDown, .expandUp])
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
                case .fileHeader, .spacer, .notice:
                    Issue.record("folding a single file never emits synthetic rows")
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
