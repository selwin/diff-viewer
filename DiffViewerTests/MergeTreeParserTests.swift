import Testing

@testable import DiffViewer

struct MergeTreeParserTests {
    private let oid = "db33077470156eefab0c0fa8adfe4effaefc33e"

    /// A conflict git does not name a file for looks the same as a clean merge here; the
    /// exit status tells them apart.
    @Test func anOutputWithOnlyTheTreeNamesNoPaths() {
        #expect(MergeTreeParser.conflictedPaths("\(oid)\0").isEmpty)
        #expect(MergeTreeParser.conflictedPaths("").isEmpty)
    }

    /// `-z` leaves names unquoted, so newlines and tabs belong to the path.
    @Test func pathsKeepTheirOrderAndAnyCharacter() {
        let output = "\(oid)\0nl\nx.txt\0sp ace.txt\0ta\tb.txt\0"
        #expect(MergeTreeParser.conflictedPaths(output) == ["nl\nx.txt", "sp ace.txt", "ta\tb.txt"])
    }

    @Test func aRepeatedPathIsListedOnce() {
        #expect(MergeTreeParser.conflictedPaths("\(oid)\0b\0a\0b\0") == ["b", "a"])
    }
}
