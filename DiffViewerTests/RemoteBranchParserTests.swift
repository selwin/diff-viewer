import Foundation
import Testing

@testable import DiffViewer

struct RemoteBranchParserTests {
    private static let date = "2026-09-19T10:00:00+00:00"
    private static let origin = ["origin": ["+refs/heads/*:refs/remotes/origin/*"]]

    /// One ref line in the layout `GitClient.remoteBranches` asks git for.
    private func line(
        ref: String = "refs/remotes/origin/main",
        symref: String = "",
        sha: String = "abc123",
        author: String = "Ada Lovelace",
        date: String = RemoteBranchParserTests.date
    ) -> String {
        [ref, symref, sha, author, date].joined(separator: "\0")
    }

    private func parse(_ lines: [String], _ refspecs: [String: [String]] = origin) throws -> [RemoteBranch] {
        try RemoteBranchParser.parse(lines.joined(separator: "\n") + "\n", refspecsByRemote: refspecs)
    }

    @Test func everyFieldIsRead() throws {
        #expect(
            try parse([line()]) == [
                RemoteBranch(
                    remote: "origin", name: "main", ref: "refs/remotes/origin/main", tipSha: "abc123",
                    tipCommitAuthor: "Ada Lovelace",
                    tipCommittedAt: try #require(ISO8601DateFormatter().date(from: Self.date)))
            ])
    }

    @Test func symrefsAreSkipped() throws {
        let branches = try parse([
            line(ref: "refs/remotes/origin/HEAD", symref: "refs/remotes/origin/main"),
            line(ref: "refs/remotes/origin/feature/x"),
        ])
        #expect(branches.map(\.name) == ["feature/x"])
    }

    /// The mapping names the remote, whatever the ref's path suggests.
    @Test func theRemoteComesFromTheMapping() throws {
        let branches = try parse(
            [line(ref: "refs/remotes/company/main")], ["origin": ["+refs/heads/*:refs/remotes/company/*"]])
        #expect(branches.map(\.remote) == ["origin"])
        #expect(branches.map(\.name) == ["main"])
    }

    /// Two remotes that could both have stored the ref: git's `--track` refuses it, so it is
    /// not offered.
    @Test func anAmbiguousRefIsSkipped() throws {
        let refspecs = [
            "team": ["+refs/heads/*:refs/remotes/team/*"],
            "team/a": ["+refs/heads/*:refs/remotes/team/a/*"],
        ]
        let branches = try parse([line(ref: "refs/remotes/team/a/x"), line(ref: "refs/remotes/team/b")], refspecs)
        #expect(branches.map(\.ref) == ["refs/remotes/team/b"])
        #expect(branches.map(\.remote) == ["team"])
    }

    @Test func unmappedAndNonBranchRefsAreSkipped() throws {
        let refspecs = ["origin": ["+refs/pull/*/head:refs/remotes/origin/pr/*"]]
        let branches = try parse(
            [line(ref: "refs/remotes/origin/pr/12"), line(ref: "refs/remotes/gone/main")], refspecs)
        #expect(branches.isEmpty)
    }

    @Test func malformedRecordsThrow() {
        #expect(throws: BranchParseError.self) {
            try parse(["refs/remotes/origin/main\0"])
        }
        #expect(throws: BranchParseError.self) {
            try parse([line(date: "not a date")])
        }
    }
}
