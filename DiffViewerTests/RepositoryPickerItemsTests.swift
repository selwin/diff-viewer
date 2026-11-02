import Testing

@testable import DiffViewer

struct RepositoryPickerItemsTests {
    private static func root(_ name: String) -> RepositoryRoot {
        RepositoryRoot(path: "/Picker/\(name)")
    }

    @Test func theCurrentRepositoryLeadsThenOpenOnesThenRecentOnesEachOnce() {
        let (a, b, c, d, e) = (Self.root("a"), Self.root("b"), Self.root("c"), Self.root("d"), Self.root("e"))
        let items = RepositoryPickerItems(current: c, open: [a, c, b], recents: [b, d, a, e])

        #expect(items.rows.map(\.root) == [c, a, b, d, e])
        #expect(items.rows.map(\.isCurrent) == [true, false, false, false, false])
    }

    @Test func shortcutsRunFromTwoToNineOverTheRowsOtherThanTheCurrentOne() {
        let others = (0..<10).map { Self.root("r\($0)") }
        let items = RepositoryPickerItems(current: Self.root("current"), open: [], recents: others)
        #expect(items.rows.map(\.shortcutDigit) == [nil, 2, 3, 4, 5, 6, 7, 8, 9, nil, nil])
    }

    @Test func withoutACurrentRepositoryShortcutsStartAtTheFirstRow() {
        let items = RepositoryPickerItems(current: nil, open: [], recents: [Self.root("a"), Self.root("b")])
        #expect(items.rows.map(\.shortcutDigit) == [2, 3])
    }
}
