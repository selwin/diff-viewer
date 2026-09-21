import Foundation
import Testing

@testable import DiffViewer

/// Builds the stream `git log -z --format=%H%x00%h%x00%P%x00%cI%x00%s` produces:
/// five NUL-separated fields per commit, with `-z`'s terminator after each.
private func logStream(_ records: [[String]]) -> Data {
    var data = Data()
    for record in records {
        for field in record {
            data.append(Data(field.utf8))
            data.append(0)
        }
    }
    return data
}

private let shaA = String(repeating: "a", count: 40)
private let shaB = String(repeating: "b", count: 40)

struct GitLogParserTests {
    @Test func parsesEveryField() throws {
        let commits = try GitLogParser.parse(
            logStream([[shaA, "aaaaaaa", shaB, "2026-09-13T11:34:09+07:00", "Add the picker"]]))
        #expect(commits.count == 1)
        let commit = try #require(commits.first)
        #expect(commit.ref.sha == shaA)
        #expect(commit.ref.shortSha == "aaaaaaa")
        #expect(commit.ref.firstParentSHA == shaB)
        #expect(commit.parents == [shaB])
        #expect(commit.subject == "Add the picker")
        #expect(commit.committedAt == Date(timeIntervalSince1970: 1_789_274_049))
        #expect(!commit.isMerge)
        #expect(!commit.isRoot)
    }

    /// The reason records are read positionally rather than by looking for something
    /// that resembles an object id: this subject *is* one.
    @Test func subjectThatLooksLikeAnObjectIDStaysOneRecord() throws {
        let commits = try GitLogParser.parse(
            logStream([
                [shaA, "aaaaaaa", shaB, "2026-09-13T11:34:09+07:00", shaB],
                [shaB, "bbbbbbb", shaA, "2026-09-12T09:00:00+07:00", "Earlier"],
            ]))
        #expect(commits.count == 2)
        #expect(commits.first?.subject == shaB)
        #expect(commits.last?.subject == "Earlier")
    }

    @Test func separatorBytesInASubjectAreOrdinaryContent() throws {
        let subject = "Weird \u{1f} and \u{1e} bytes"
        let commits = try GitLogParser.parse(
            logStream([[shaA, "aaaaaaa", shaB, "2026-09-13T11:34:09+07:00", subject]]))
        #expect(commits.first?.subject == subject)
    }

    @Test func rootCommitHasNoParents() throws {
        let commits = try GitLogParser.parse(
            logStream([[shaA, "aaaaaaa", "", "2026-09-13T11:34:09+07:00", "First"]]))
        #expect(commits.first?.parents.isEmpty == true)
        #expect(commits.first?.ref.firstParentSHA == nil)
        #expect(commits.first?.isRoot == true)
    }

    @Test func mergeKeepsEveryParentAndComparesAgainstTheFirst() throws {
        let commits = try GitLogParser.parse(
            logStream([[shaA, "aaaaaaa", "\(shaB) \(shaA)", "2026-09-13T11:34:09+07:00", "Merge"]]))
        #expect(commits.first?.parents == [shaB, shaA])
        #expect(commits.first?.ref.firstParentSHA == shaB)
        #expect(commits.first?.isMerge == true)
    }

    @Test func parsesASHA256ObjectID() throws {
        let long = String(repeating: "c", count: 64)
        let commits = try GitLogParser.parse(
            logStream([[long, "ccccccc", "", "2026-09-13T11:34:09+07:00", "SHA-256"]]))
        #expect(commits.first?.ref.sha == long)
    }

    @Test func emptyOutputIsNoCommits() throws {
        #expect(try GitLogParser.parse(Data()).isEmpty)
    }

    @Test func truncatedRecordThrowsRatherThanGuessing() {
        let partial = logStream([[shaA, "aaaaaaa", shaB]])
        #expect(throws: GitLogParseError.self) { try GitLogParser.parse(partial) }
    }

    /// `CommitRef` equality is identity only, but the summary must notice when git
    /// lengthens the abbreviation so a refreshed row is redrawn.
    @Test func aLongerAbbreviationChangesTheSummaryButNotTheRef() {
        let short = CommitSummary(
            sha: shaA, shortSha: "aaaaaaa", parents: [shaB], subject: "Same",
            committedAt: Date(timeIntervalSince1970: 1_789_274_049))
        let long = CommitSummary(
            sha: shaA, shortSha: "aaaaaaaa", parents: [shaB], subject: "Same",
            committedAt: Date(timeIntervalSince1970: 1_789_274_049))
        #expect(short.ref == long.ref)
        #expect(short != long)
    }

    @Test func aRecordNotStartingWithAnObjectIDThrows() {
        let bogus = logStream([["not-a-sha", "aaaaaaa", shaB, "2026-09-13T11:34:09+07:00", "Subject"]])
        #expect(throws: GitLogParseError.self) { try GitLogParser.parse(bogus) }
    }

    @Test func anUnreadableDateThrows() {
        let bogus = logStream([[shaA, "aaaaaaa", shaB, "yesterday", "Subject"]])
        #expect(throws: GitLogParseError.self) { try GitLogParser.parse(bogus) }
    }
}
