import Testing

@testable import DiffViewer

struct DiffPaneStyleCacheTests {
    struct Case: CustomTestStringConvertible {
        let name: String
        let index: Int
        let old: [[StyleRun]]?
        let new: [[StyleRun]]?
        let keeps: Bool

        var testDescription: String { name }
    }

    private static let keyword = [StyleRun(range: 0..<3, style: .keyword)]
    private static let string = [StyleRun(range: 0..<2, style: .string)]

    static let cases: [Case] = [
        Case(name: "old nil, new non-nil", index: 0, old: nil, new: [keyword], keeps: false),
        Case(
            name: "equal runs at the index", index: 0,
            old: [[StyleRun(range: 0..<3, style: .keyword), StyleRun(range: 3..<5, style: .string)]],
            new: [[StyleRun(range: 0..<3, style: .keyword), StyleRun(range: 3..<5, style: .string)]], keeps: true),
        Case(
            name: "different runs at the index", index: 0, old: [keyword],
            new: [[StyleRun(range: 0..<5, style: .string)]], keeps: false),
        Case(name: "index past the end of old", index: 1, old: [keyword], new: [keyword, string], keeps: false),
        Case(name: "index past the end of new", index: 1, old: [keyword, string], new: [keyword], keeps: false),
        Case(name: "new nil", index: 0, old: [keyword], new: nil, keeps: false),
    ]

    @Test(arguments: cases) func aShapedLineSurvivesOnlyWhenBothSnapshotsHoldEqualRuns(_ testCase: Case) {
        let keeps = DiffPaneView.keepsShapedLine(at: testCase.index, old: testCase.old, new: testCase.new)
        #expect(keeps == testCase.keeps)
    }
}
