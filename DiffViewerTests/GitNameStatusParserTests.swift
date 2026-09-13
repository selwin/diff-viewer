import Foundation
import Testing

@testable import DiffViewer

struct GitNameStatusParserTests {
    private let commit = CommitRef(
        sha: String(repeating: "a", count: 40), shortSha: "aaaaaaa",
        firstParentSHA: String(repeating: "b", count: 40))

    private func data(_ fields: [String]) -> Data {
        Data((fields.joined(separator: "\0") + "\0").utf8)
    }

    @Test func readsStatusAndPathPairs() {
        let files = GitNameStatusParser.parse(
            data(["M", "src/a.swift", "A", "src/b.swift", "D", "src/c.swift"]), area: .commit(commit))
        #expect(files.map(\.path) == ["src/a.swift", "src/b.swift", "src/c.swift"])
        #expect(files.map(\.kind) == [.modified, .added, .deleted])
        #expect(files.allSatisfy { $0.area == .commit(commit) })
    }

    @Test func idsCarryTheCommit() {
        let files = GitNameStatusParser.parse(data(["M", "src/a.swift"]), area: .commit(commit))
        #expect(files.first?.id == "commit:\(commit.sha):src/a.swift")
    }

    @Test func sortsByPath() {
        let files = GitNameStatusParser.parse(data(["M", "z.swift", "M", "a.swift"]), area: .commit(commit))
        #expect(files.map(\.path) == ["a.swift", "z.swift"])
    }

    @Test func keepsPathsWithSpacesAndUnicode() {
        let files = GitNameStatusParser.parse(
            data(["T", "src/a file.swift", "M", "docs/ünïcode.md"]), area: .commit(commit))
        #expect(files.map(\.path) == ["docs/ünïcode.md", "src/a file.swift"])
        #expect(files.map(\.kind) == [.modified, .typeChanged])
    }

    /// `--no-renames` should keep these out, but a rename carries two paths and would
    /// otherwise shift every record after it.
    @Test func renameConsumesBothPaths() {
        let files = GitNameStatusParser.parse(
            data(["R100", "old.swift", "new.swift", "M", "after.swift"]), area: .commit(commit))
        #expect(files.map(\.path) == ["after.swift", "new.swift"])
        #expect(files.first(where: { $0.path == "new.swift" })?.originalPath == "old.swift")
    }

    @Test func emptyOutputIsNoFiles() {
        #expect(GitNameStatusParser.parse(Data(), area: .commit(commit)).isEmpty)
    }

    @Test func trailingStatusWithoutAPathIsSkipped() {
        let files = GitNameStatusParser.parse(data(["M", "a.swift", "M"]), area: .commit(commit))
        #expect(files.map(\.path) == ["a.swift"])
    }
}
