import CoreGraphics
import Testing

@testable import DiffViewer

/// Which document row a pointer height lands on. `row(atY:)` clamps on purpose, so a drag
/// past either end still selects the first or last row.
struct PaneHitTestTests {
    struct Case: CustomTestStringConvertible {
        let name: String
        let y: CGFloat
        let displayRows: [DisplayRow]
        let rowCount: Int
        let expected: (index: Int, row: Int)?

        var testDescription: String { name }
    }

    private static let threeRows: [DisplayRow] = [.documentRow(0), .documentRow(1), .documentRow(2)]

    static let cases: [Case] = [
        Case(name: "first row", y: 5, displayRows: threeRows, rowCount: 3, expected: (0, 0)),
        Case(name: "last row", y: 25, displayRows: threeRows, rowCount: 3, expected: (2, 2)),
        Case(name: "below the content clamps", y: 500, displayRows: threeRows, rowCount: 3, expected: (2, 2)),
        Case(name: "negative y clamps", y: -20, displayRows: threeRows, rowCount: 3, expected: (0, 0)),
        Case(
            name: "separator row", y: 15, displayRows: [.documentRow(0), .separator(hidden: 1..<5), .documentRow(5)],
            rowCount: 6, expected: nil),
        Case(name: "no display rows", y: 5, displayRows: [], rowCount: 3, expected: nil),
        Case(name: "negative document row", y: 5, displayRows: [.documentRow(-1)], rowCount: 3, expected: nil),
        Case(name: "document row past the end", y: 5, displayRows: [.documentRow(3)], rowCount: 3, expected: nil),
    ]

    @Test(arguments: cases) func documentRowUnderY(_ testCase: Case) {
        let layout = PaneLayout(rowHeight: 10, rowCount: testCase.displayRows.count)
        let hit = DiffPaneView.documentRow(
            atY: testCase.y, layout: layout, displayRows: testCase.displayRows, rowCount: testCase.rowCount)
        #expect(hit?.index == testCase.expected?.index)
        #expect(hit?.row == testCase.expected?.row)
    }
}
