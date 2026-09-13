import Testing

@testable import DiffViewer

struct PaneLayoutTests {
    @Test func rowRangesFollowFixedHeights() {
        let layout = PaneLayout(rowHeight: 20, rowCount: 100)
        #expect(layout.contentHeight == 2000)
        #expect(layout.y(forRow: 3) == 60)
        #expect(layout.rows(intersecting: 0, 100) == 0..<5)
        #expect(layout.rows(intersecting: 10, 30) == 0..<2)
        #expect(layout.rows(intersecting: 1990, 5000) == 99..<100)
        #expect(layout.rows(intersecting: 3000, 4000) == 0..<0)
        #expect(PaneLayout(rowHeight: 20, rowCount: 0).rows(intersecting: 0, 100) == 0..<0)
    }

    @Test func rowAtYClamps() {
        let layout = PaneLayout(rowHeight: 10, rowCount: 5)
        #expect(layout.row(atY: -5) == 0)
        #expect(layout.row(atY: 25) == 2)
        #expect(layout.row(atY: 999) == 4)
    }

    @Test func tabExpansionMapsOffsets() {
        let (text, map) = TabExpander.expand("a\tb\t\tc", tabWidth: 4)
        #expect(text == "a   b       c")
        #expect(map == [0, 1, 4, 5, 8, 12, 13])
        #expect(TabExpander.expand("plain", tabWidth: 4).map == nil)
    }
}
