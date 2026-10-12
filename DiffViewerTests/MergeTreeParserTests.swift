import Testing

@testable import DiffViewer

struct MergeTreeParserTests {
    private let oid = "db33077470156eefab0c0fa8adfe4effaefc33e"

    /// A tree id, the paths, the empty separator, then the message records, as git writes them.
    private func output(paths: [String], records: [String] = []) -> String {
        ([oid] + paths + [""] + records + [""]).joined(separator: "\0")
    }

    private func record(_ paths: [String], _ type: String, _ message: String = "") -> String {
        ([String(paths.count)] + paths + [type, message]).joined(separator: "\0")
    }

    private func kinds(_ output: String) -> [MergeConflictKind] {
        MergeTreeParser.conflicts(output).map(\.kind)
    }

    /// A conflict git does not name a file for looks the same as a clean merge here; the
    /// exit status tells them apart.
    @Test func anOutputWithNoPathsGivesNoConflicts() {
        #expect(MergeTreeParser.conflicts("\(oid)\0").isEmpty)
        #expect(MergeTreeParser.conflicts("").isEmpty)
        #expect(MergeTreeParser.conflicts(output(paths: [], records: [record(["x"], "CONFLICT (contents)")])).isEmpty)
    }

    /// `-z` leaves names unquoted, so newlines and tabs belong to the path.
    @Test func pathsKeepTheirOrderAndAnyCharacterAndAreListedOnce() {
        let paths = ["nl\nx.txt", "sp ace.txt", "ta\tb.txt", "sp ace.txt"]
        #expect(
            MergeTreeParser.conflicts(output(paths: paths))
                == [
                    MergeConflict(path: "nl\nx.txt", kind: .other),
                    MergeConflict(path: "sp ace.txt", kind: .other),
                    MergeConflict(path: "ta\tb.txt", kind: .other),
                ])
        #expect(MergeTreeParser.conflicts("\(oid)\0b\0a\0b\0").map(\.path) == ["b", "a"])
    }

    @Test(arguments: [
        ("CONFLICT (contents)", "CONFLICT (content): Merge conflict in x", MergeConflictKind.contents),
        ("CONFLICT (contents)", "CONFLICT (add/add): Merge conflict in x", .addAdd),
        ("CONFLICT (binary)", "warning: Cannot merge binary files: x", .contents),
        ("CONFLICT (modify/delete)", "x deleted in side and modified in main.", .modifyDelete),
        ("CONFLICT (rename/delete)", "x renamed to y in side, but deleted in main.", .renameDelete),
        ("CONFLICT (rename/rename)", "x renamed to y in main and to z in side.", .renameRename),
        ("CONFLICT (file/directory)", "directory in the way of x from main.", .fileDirectory),
        ("CONFLICT (submodule failed to merge)", "Failed to merge submodule x", .other),
        ("Auto-merging", "Auto-merging x", .other),
    ])
    func aRecordTypeMapsToItsKind(type: String, message: String, kind: MergeConflictKind) {
        #expect(kinds(output(paths: ["x"], records: [record(["x"], type, message)])) == [kind])
    }

    struct KindRecord: Sendable {
        let type: String
        let message: String
        let kind: MergeConflictKind
    }

    /// One record per kind, in the parser's display priority, strongest first.
    static let recordsByPriority = [
        KindRecord(type: "CONFLICT (modify/delete)", message: "", kind: .modifyDelete),
        KindRecord(type: "CONFLICT (rename/delete)", message: "", kind: .renameDelete),
        KindRecord(type: "CONFLICT (rename/rename)", message: "", kind: .renameRename),
        KindRecord(type: "CONFLICT (file/directory)", message: "", kind: .fileDirectory),
        KindRecord(type: "CONFLICT (contents)", message: "CONFLICT (add/add): Merge conflict in x", kind: .addAdd),
        KindRecord(type: "CONFLICT (contents)", message: "CONFLICT (content): Merge conflict in x", kind: .contents),
        KindRecord(type: "CONFLICT (submodule failed to merge)", message: "", kind: .other),
    ]

    /// Each kind against the next one down, so the whole order is pinned.
    @Test(arguments: Array(1..<MergeTreeParserTests.recordsByPriority.count))
    func theHigherPriorityKindWinsInEitherOrder(weakerRank: Int) {
        let stronger = Self.recordsByPriority[weakerRank - 1]
        let weaker = Self.recordsByPriority[weakerRank]
        let records = [stronger, weaker].map { record(["x"], $0.type, $0.message) }
        #expect(kinds(output(paths: ["x"], records: records)) == [stronger.kind])
        #expect(kinds(output(paths: ["x"], records: records.reversed())) == [stronger.kind])
    }

    /// The last record lacks its message, has one without the closing NUL, or claims more
    /// paths than any output could hold.
    @Test(arguments: [
        "1\0x\0CONFLICT (modify/delete)\0",
        "1\0x\0CONFLICT (modify/delete)\0x deleted in side",
        "\(Int.max)\0x\0CONFLICT (modify/delete)\0\0",
    ])
    func anIncompleteRecordNamesNoKind(record: String) {
        #expect(kinds("\(oid)\0x\0\0" + record) == [.other])
    }

    @Test func aMalformedRecordKeepsEarlierKindsAndEveryPath() {
        let first = record(["a"], "CONFLICT (modify/delete)")
        let later = record(["c"], "CONFLICT (contents)")
        let truncated = ["9", "b", "CONFLICT (contents)"]
        let notANumber = ["many", "b", "CONFLICT (contents)", ""]

        for broken in [truncated, notANumber] {
            let text = ([oid, "a", "b", "c", ""] + [first] + broken + [later, ""]).joined(separator: "\0")
            #expect(
                MergeTreeParser.conflicts(text)
                    == [
                        MergeConflict(path: "a", kind: .modifyDelete),
                        MergeConflict(path: "b", kind: .other),
                        MergeConflict(path: "c", kind: .other),
                    ])
        }
    }

    /// Both old and new names appear in a rename record; only the conflicted file is listed.
    @Test func aRecordNamingAPathOutsideThePathSectionAddsNothing() {
        let text = output(
            paths: ["rd-side.txt"],
            records: [record(["rd-side.txt", "rd.txt"], "CONFLICT (rename/delete)")])
        #expect(MergeTreeParser.conflicts(text) == [MergeConflict(path: "rd-side.txt", kind: .renameDelete)])
    }
}
