import Foundation
import Testing

@testable import DiffViewer

struct GitStatusParserTests {
    private func data(_ records: [String]) -> Data {
        Data((records.joined(separator: "\0") + "\0").utf8)
    }

    @Test func modifiedInWorktreeOnly() {
        let files = GitStatusParser.parse(data(["1 .M N... 100644 100644 100644 abc def src/a.swift"]))
        #expect(files == [ChangedFile(path: "src/a.swift", originalPath: nil, kind: .modified, area: .unstaged)])
    }

    @Test func stagedAndUnstagedProducesTwoEntries() {
        let files = GitStatusParser.parse(data(["1 MM N... 100644 100644 100644 abc def a.txt"]))
        #expect(files.map(\.area) == [.staged, .unstaged])
        #expect(files.allSatisfy { $0.path == "a.txt" && $0.kind == .modified })
    }

    @Test func stagedAddition() {
        let files = GitStatusParser.parse(data(["1 A. N... 000000 100644 100644 000 def new.txt"]))
        #expect(files == [ChangedFile(path: "new.txt", originalPath: nil, kind: .added, area: .staged)])
    }

    @Test func renameCarriesOriginalPath() {
        let files = GitStatusParser.parse(
            data(["2 R. N... 100644 100644 100644 abc abc R100 new/name.txt", "old/name.txt"]))
        #expect(
            files == [ChangedFile(path: "new/name.txt", originalPath: "old/name.txt", kind: .renamed, area: .staged)])
    }

    @Test func untrackedAndConflict() {
        let files = GitStatusParser.parse(
            data([
                "? notes.md",
                "u UU N... 100644 100644 100644 100644 a b c d conflict.txt",
            ]))
        #expect(files.map(\.kind) == [.untracked, .unmerged])
        #expect(files.allSatisfy { $0.area == .unstaged })
    }

    @Test func pathsWithSpacesSurvive() {
        let files = GitStatusParser.parse(data(["1 .M N... 100644 100644 100644 abc def dir with space/file name.txt"]))
        #expect(files.first?.path == "dir with space/file name.txt")
    }

    @Test func emptyInputYieldsNothing() {
        #expect(GitStatusParser.parse(Data()).isEmpty)
    }
}
