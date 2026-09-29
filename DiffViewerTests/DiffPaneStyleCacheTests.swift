import Testing

@testable import DiffViewer

struct DiffPaneStyleCacheTests {
    @Test func oldNilNewNonNilReturnsFalse() {
        let new = [[StyleRun(range: 0..<3, style: .keyword)]]
        #expect(!DiffPaneView.keepsShapedLine(at: 0, old: nil, new: new))
    }

    @Test func equalRunsAtIndexReturnsTrue() {
        let runs = [StyleRun(range: 0..<3, style: .keyword), StyleRun(range: 3..<5, style: .string)]
        let old = [runs]
        let new = [runs]
        #expect(DiffPaneView.keepsShapedLine(at: 0, old: old, new: new))
    }

    @Test func differentRunsAtIndexReturnsFalse() {
        let old = [[StyleRun(range: 0..<3, style: .keyword)]]
        let new = [[StyleRun(range: 0..<5, style: .string)]]
        #expect(!DiffPaneView.keepsShapedLine(at: 0, old: old, new: new))
    }

    @Test func indexPastEndOfOldReturnsFalse() {
        let old = [[StyleRun(range: 0..<3, style: .keyword)]]
        let new = [[StyleRun(range: 0..<3, style: .keyword)], [StyleRun(range: 0..<2, style: .string)]]
        #expect(!DiffPaneView.keepsShapedLine(at: 1, old: old, new: new))
    }

    @Test func indexPastEndOfNewReturnsFalse() {
        let old = [[StyleRun(range: 0..<3, style: .keyword)], [StyleRun(range: 0..<2, style: .string)]]
        let new = [[StyleRun(range: 0..<3, style: .keyword)]]
        #expect(!DiffPaneView.keepsShapedLine(at: 1, old: old, new: new))
    }

    @Test func newNilReturnsFalse() {
        let old = [[StyleRun(range: 0..<3, style: .keyword)]]
        #expect(!DiffPaneView.keepsShapedLine(at: 0, old: old, new: nil))
    }
}
