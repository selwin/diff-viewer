import Foundation
import Testing

@testable import DiffViewer

private let commit = CommitRef(
    sha: String(repeating: "a", count: 40), shortSha: "aaaaaaa",
    firstParentSHA: String(repeating: "b", count: 40))

private func parse(_ fields: [String]) -> [ChangedFile] {
    let data = fields.isEmpty ? Data() : Data((fields.joined(separator: "\0") + "\0").utf8)
    return GitNameStatusParser.parse(data, area: .commit(commit))
}

struct GitNameStatusParserTests {
    /// Status and path pairs, sorted by path, with spaces and Unicode in paths preserved.
    /// A trailing status without its path is dropped.
    @Test(
        arguments: [
            (
                ["M", "src/a.swift", "A", "src/b.swift", "D", "src/c.swift"],
                [
                    ("src/a.swift", ChangedFile.Kind.modified), ("src/b.swift", .added), ("src/c.swift", .deleted),
                ]
            ),
            (["M", "z.swift", "M", "a.swift"], [("a.swift", .modified), ("z.swift", .modified)]),
            (
                ["T", "src/a file.swift", "M", "docs/ünïcode.md"],
                [("docs/ünïcode.md", .modified), ("src/a file.swift", .typeChanged)]
            ),
            ([], []),
            (["M", "a.swift", "M"], [("a.swift", .modified)]),
        ] as [([String], [(String, ChangedFile.Kind)])])
    func readsStatusAndPathPairs(fields: [String], expected: [(String, ChangedFile.Kind)]) {
        let files = parse(fields)
        #expect(files.map(\.path) == expected.map(\.0))
        #expect(files.map(\.kind) == expected.map(\.1))
        #expect(files.allSatisfy { $0.area == .commit(commit) })
    }

    @Test func idsCarryTheCommit() {
        #expect(parse(["M", "src/a.swift"]).first?.id == "commit:\(commit.sha):src/a.swift")
    }

    /// A rename carries two paths; reading only one would shift every record after it.
    @Test func renameConsumesBothPaths() {
        let files = parse(["R100", "old.swift", "new.swift", "M", "after.swift"])
        #expect(files.map(\.path) == ["after.swift", "new.swift"])
        #expect(files.first(where: { $0.path == "new.swift" })?.originalPath == "old.swift")
    }
}
