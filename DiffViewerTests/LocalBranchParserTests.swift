import Foundation
import Testing

@testable import DiffViewer

struct LocalBranchParserTests {
    private static let date = "2026-09-19T10:00:00+00:00"

    /// One branch line in the layout `GitClient.localBranches` asks git for.
    private func line(
        ref: String = "refs/heads/main",
        shortName: String = "origin/main",
        track: String = "",
        remote: String = "origin",
        remoteRef: String = "refs/heads/main",
        date: String = LocalBranchParserTests.date,
        localRef: String = "refs/remotes/origin/main"
    ) -> String {
        [ref, shortName, track, remote, remoteRef, date, localRef].joined(separator: "\0")
    }

    @Test func everyUpstreamFieldIsRead() throws {
        let branches = try LocalBranchParser.parse(line(track: "ahead 1, behind 2") + "\n")
        #expect(branches.count == 1)
        let branch = try #require(branches.first)
        #expect(branch.name == "main")
        #expect(branch.tipCommittedAt == ISO8601DateFormatter().date(from: Self.date))
        let upstream = try #require(branch.upstream)
        #expect(upstream.shortName == "origin/main")
        #expect(upstream.remote == "origin")
        #expect(upstream.remoteRef == "refs/heads/main")
        #expect(upstream.localRef == "refs/remotes/origin/main")
        #expect(upstream.tracking == .counts(ahead: 1, behind: 2))
    }

    /// The short name is what says there is an upstream at all; git can leave the other
    /// fields populated from a configuration that no longer resolves.
    @Test func anEmptyShortNameMeansNoUpstream() throws {
        let branches = try LocalBranchParser.parse(line(shortName: "", track: "gone") + "\n")
        #expect(branches.first?.upstream == nil)
    }

    @Test func goneIsCarriedThrough() throws {
        let branches = try LocalBranchParser.parse(line(track: "gone") + "\n")
        #expect(branches.first?.upstream?.tracking == .gone)
    }

    @Test func anUnreadableDateThrows() {
        #expect(throws: LocalBranchParseError.self) {
            try LocalBranchParser.parse(line(date: "not a date") + "\n")
        }
    }

    @Test func aRecordWithoutSevenFieldsThrows() {
        #expect(throws: LocalBranchParseError.self) {
            try LocalBranchParser.parse("refs/heads/main\0origin/main\n")
        }
    }

    /// git allows a Unicode line separator inside a ref name and a non-breaking space at
    /// its end; splitting on `isNewline` or trimming whitespace would corrupt both.
    @Test func oddNamesSurvive() throws {
        let name = "odd\u{2028}name\u{00A0}"
        let branches = try LocalBranchParser.parse(line(ref: "refs/heads/\(name)", shortName: "") + "\n")
        #expect(branches.map(\.name) == [name])
    }

    @Test func everyLineBecomesABranch() throws {
        let lines = [
            line(ref: "refs/heads/feature", shortName: "", remote: "", remoteRef: "", localRef: ""),
            line(track: "behind 3"),
            line(
                ref: "refs/heads/zeta", shortName: "upstream/zeta", remote: "upstream",
                remoteRef: "refs/heads/zeta", localRef: "refs/remotes/mirror/zeta"),
        ]
        let output = lines.joined(separator: "\n") + "\n"

        let branches = try LocalBranchParser.parse(output)
        #expect(branches.map(\.name) == ["feature", "main", "zeta"])
        #expect(branches.map { $0.upstream?.shortName } == [nil, "origin/main", "upstream/zeta"])
        #expect(branches.last?.upstream?.remote == "upstream")
        #expect(branches.last?.upstream?.localRef == "refs/remotes/mirror/zeta")
    }
}
