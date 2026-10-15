import Foundation
import Testing

@testable import DiffViewer

struct GitRefParserTests {
    /// One line in the layout `GitClient.refs` asks git for.
    private func line(
        _ ref: String, symref: String = "", type: String = "commit", sha: String = objectID("c"),
        date: String = "1700000000", peeledType: String = "", peeledSha: String = "", peeledDate: String = ""
    ) -> String {
        [ref, symref, type, sha, date, peeledType, peeledSha, peeledDate].joined(separator: "\0") + "\n"
    }

    @Test func annotatedTagsTakeTheirPeeledCommit() throws {
        let output =
            line("refs/heads/main")
            + line(
                "refs/tags/v1", type: "tag", sha: objectID("tag"), date: "", peeledType: "commit",
                peeledSha: objectID("peeled"), peeledDate: "1600000000")
        let refs = try GitRefParser.parse(output)

        #expect(refs.map(\.kind) == [.local, .tag])
        #expect(refs[0].commitSHA == objectID("c"))
        #expect(refs[0].committedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(refs[1].commitSHA == objectID("peeled"))
        #expect(refs[1].committedAt == Date(timeIntervalSince1970: 1_600_000_000))
    }

    @Test func symrefsAndTagsOfNonCommitsAreDropped() throws {
        let output =
            line("refs/remotes/origin/main")
            + line("refs/remotes/origin/HEAD", symref: "refs/remotes/origin/main")
            + line("refs/tags/tree", type: "tag", sha: objectID("tag"), date: "", peeledType: "tree")
        let refs = try GitRefParser.parse(output)

        #expect(refs.map(\.fullName) == ["refs/remotes/origin/main"])
    }

    @Test func aBranchAndATagWithOneNameStayDistinct() throws {
        let refs = try GitRefParser.parse(line("refs/heads/v1") + line("refs/tags/v1"))
        #expect(refs.map(\.fullName) == ["refs/heads/v1", "refs/tags/v1"])
        #expect(Set(refs.map(\.id)).count == 2)
    }

    @Test func malformedRecordsThrow() {
        for output in [line("refs/heads/main", date: "soon"), "refs/heads/main\0\0commit\n"] {
            #expect(throws: BranchParseError.self) { try GitRefParser.parse(output) }
        }
    }
}

struct CompareRefOrderingTests {
    private func ref(_ fullName: String, _ kind: GitRef.Kind, _ date: TimeInterval) -> GitRef {
        let prefix = ["refs/heads/", "refs/remotes/", "refs/tags/"].first(where: fullName.hasPrefix) ?? ""
        return GitRef(
            fullName: fullName, name: String(fullName.dropFirst(prefix.count)), kind: kind,
            commitSHA: objectID("c"), committedAt: Date(timeIntervalSince1970: date))
    }

    @Test func groupsThenNewestFirstThenFullName() {
        let refs = [
            ref("refs/tags/v1", .tag, 900),
            ref("refs/remotes/origin/main", .remote, 100),
            ref("refs/heads/old", .local, 100),
            ref("refs/heads/new", .local, 500),
            ref("refs/heads/current", .local, 50),
            ref("refs/heads/b", .local, 300),
            ref("refs/heads/a", .local, 300),
        ]
        let sorted = CompareRefOrdering.sorted(refs, currentBranch: "current")
        #expect(
            sorted.map(\.fullName) == [
                "refs/heads/current", "refs/heads/new", "refs/heads/a", "refs/heads/b", "refs/heads/old",
                "refs/remotes/origin/main", "refs/tags/v1",
            ])
    }
}
