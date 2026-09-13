import Foundation
import Testing

@testable import DiffViewer

struct GitNumstatParserTests {
    private func data(_ records: [String]) -> Data {
        Data((records.joined(separator: "\0") + "\0").utf8)
    }

    @Test func plainEntryCarriesCounts() {
        let entries = GitNumstatParser.parse(data(["12\t4\tsrc/a.swift"]))
        #expect(entries == [NumstatEntry(path: "src/a.swift", stats: .counted(added: 12, deleted: 4))])
    }

    @Test func binaryEntry() {
        let entries = GitNumstatParser.parse(data(["-\t-\tbin.dat"]))
        #expect(entries == [NumstatEntry(path: "bin.dat", stats: .binary)])
    }

    @Test func renameFramingReportsNewPath() {
        let entries = GitNumstatParser.parse(data(["3\t1\t", "old/name.txt", "new/name.txt"]))
        #expect(entries == [NumstatEntry(path: "new/name.txt", stats: .counted(added: 3, deleted: 1))])
    }

    @Test func renameFramingDoesNotSwallowTheNextRecord() {
        let entries = GitNumstatParser.parse(data(["3\t1\t", "old.txt", "new.txt", "2\t0\tafter.txt"]))
        #expect(entries.map(\.path) == ["new.txt", "after.txt"])
    }

    @Test func pathWithSpacesSurvives() {
        let entries = GitNumstatParser.parse(data(["1\t0\tdir with space/file name.txt"]))
        #expect(entries.first?.path == "dir with space/file name.txt")
    }

    @Test func pathWithTabSurvivesAndTheNextRecordStillParses() {
        // git -z emits unquoted paths, so a tab in a filename is part of the path.
        let entries = GitNumstatParser.parse(data(["2\t1\ttab\tname.txt", "5\t6\tgood.txt"]))
        #expect(
            entries == [
                NumstatEntry(path: "tab\tname.txt", stats: .counted(added: 2, deleted: 1)),
                NumstatEntry(path: "good.txt", stats: .counted(added: 5, deleted: 6)),
            ])
    }

    @Test func twoEntriesInOneBuffer() {
        let entries = GitNumstatParser.parse(data(["1\t2\ta.txt", "-\t-\tb.bin"]))
        #expect(
            entries == [
                NumstatEntry(path: "a.txt", stats: .counted(added: 1, deleted: 2)),
                NumstatEntry(path: "b.bin", stats: .binary),
            ])
    }

    @Test func emptyInputYieldsNothing() {
        #expect(GitNumstatParser.parse(Data()).isEmpty)
    }

    @Test func recordWithOneTabIsSkippedAndParsingContinues() {
        let entries = GitNumstatParser.parse(data(["1\tbroken.txt", "5\t6\tgood.txt"]))
        #expect(entries == [NumstatEntry(path: "good.txt", stats: .counted(added: 5, deleted: 6))])
    }

    @Test func nonNumericCountsAreSkipped() {
        let entries = GitNumstatParser.parse(data(["x\ty\tbad.txt", "5\t6\tgood.txt"]))
        #expect(entries.map(\.path) == ["good.txt"])
    }
}
