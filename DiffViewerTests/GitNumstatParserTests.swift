import Foundation
import Testing

@testable import DiffViewer

private func entry(_ path: String, _ added: Int, _ deleted: Int) -> NumstatEntry {
    NumstatEntry(path: path, stats: .counted(added: added, deleted: deleted))
}

struct GitNumstatParserTests {
    /// `-z` records: `added\tdeleted\tpath`, or `added\tdeleted\t` then the old and new
    /// paths as records of their own for a rename. A malformed record is skipped alone.
    @Test(
        arguments: [
            ("counts", ["12\t4\tsrc/a.swift"], [entry("src/a.swift", 12, 4)]),
            ("binary", ["-\t-\tbin.dat"], [NumstatEntry(path: "bin.dat", stats: .binary(nil))]),
            ("rename reports the new path", ["3\t1\t", "old/name.txt", "new/name.txt"], [entry("new/name.txt", 3, 1)]),
            (
                "rename then another record", ["3\t1\t", "old.txt", "new.txt", "2\t0\tafter.txt"],
                [entry("new.txt", 3, 1), entry("after.txt", 2, 0)]
            ),
            ("spaces", ["1\t0\tdir with space/file name.txt"], [entry("dir with space/file name.txt", 1, 0)]),
            // git -z emits unquoted paths, so a tab in a filename is part of the path.
            (
                "tab in a path", ["2\t1\ttab\tname.txt", "5\t6\tgood.txt"],
                [entry("tab\tname.txt", 2, 1), entry("good.txt", 5, 6)]
            ),
            (
                "counted and binary", ["1\t2\ta.txt", "-\t-\tb.bin"],
                [entry("a.txt", 1, 2), NumstatEntry(path: "b.bin", stats: .binary(nil))]
            ),
            ("empty", [], []),
            ("one tab", ["1\tbroken.txt", "5\t6\tgood.txt"], [entry("good.txt", 5, 6)]),
            ("non-numeric counts", ["x\ty\tbad.txt", "5\t6\tgood.txt"], [entry("good.txt", 5, 6)]),
        ] as [(String, [String], [NumstatEntry])])
    func parse(_ name: String, records: [String], expected: [NumstatEntry]) {
        let data = records.isEmpty ? Data() : Data((records.joined(separator: "\0") + "\0").utf8)
        #expect(GitNumstatParser.parse(data) == expected)
    }
}
