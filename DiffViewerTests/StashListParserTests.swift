import Foundation
import Testing

@testable import DiffViewer

private let shaA = String(repeating: "a", count: 40)
private let shaB = String(repeating: "b", count: 40)
private let date = "2026-09-13T11:34:09+07:00"

/// Builds what `git stash list --format=%x00%H%x00%h%x00%P%x00%cI%x00%an%x00%gs%x00
/// --shortstat` prints: NUL, six NUL-terminated fields, then the stat text.
private func listOutput(_ records: [(subject: String, stat: String)], parents: String = shaB) -> Data {
    var text = ""
    for record in records {
        text += "\0\(shaA)\0aaaaaaa\0\(parents)\0\(date)\0Ada\0\(record.subject)\0\(record.stat)"
    }
    return Data(text.utf8)
}

struct StashListParserTests {
    @Test(
        arguments: [
            ("On main: fix the picker", "fix the picker", "main", false),
            ("On feature/x: a: b", "a: b", "feature/x", false),
            ("WIP on main: aaaaaaa Add thing", "WIP on main", "main", true),
            ("On (no branch): detached work", "detached work", nil, false),
            ("WIP on (no branch): aaaaaaa Add thing", "WIP on (no branch)", nil, true),
            ("custom", "custom", nil, false),
        ] as [(String, String, String?, Bool)])
    func readsTheReflogSubject(subject: String, message: String, branch: String?, isDefault: Bool) throws {
        let entry = try #require(try StashListParser.parse(listOutput([(subject, "")])).first)
        #expect(entry.message == message)
        #expect(entry.sourceBranch == branch)
        #expect(entry.hasDefaultMessage == isDefault)
    }

    @Test(
        arguments: [
            ("\n\n 3 files changed, 5 insertions(+), 2 deletions(-)\n", StashEntry.Churn(additions: 5, deletions: 2)),
            ("\n\n 1 file changed, 1 insertion(+)\n", StashEntry.Churn(additions: 1, deletions: 0)),
            ("\n\n 2 files changed, 4 deletions(-)\n", StashEntry.Churn(additions: 0, deletions: 4)),
            ("", StashEntry.Churn(additions: 0, deletions: 0)),
            ("\n", StashEntry.Churn(additions: 0, deletions: 0)),
            ("something else", nil),
        ] as [(String, StashEntry.Churn?)])
    func readsTheShortstat(stat: String, churn: StashEntry.Churn?) throws {
        let entry = try #require(try StashListParser.parse(listOutput([("On main: m", stat)])).first)
        #expect(entry.churn == churn)
    }

    @Test func parsesRecordsInOrderWithTheirFields() throws {
        let entries = try StashListParser.parse(
            listOutput([("On main: first", ""), ("On main: second\u{1e}x", "\n\n 1 file changed, 1 insertion(+)\n")]))
        #expect(entries.map(\.stashIndex) == [0, 1])
        #expect(entries.map(\.message) == ["first", "second\u{1e}x"])
        let entry = entries[0]
        #expect(entry.sha == shaA)
        #expect(entry.shortSha == "aaaaaaa")
        #expect(entry.parents == [shaB])
        #expect(entry.author == "Ada")
        #expect(entry.committedAt == Date(timeIntervalSince1970: 1_789_274_049))
        #expect(entry.stashSelector == "stash@{0}")
    }

    @Test func threeParentsSetsHasUntrackedParent() throws {
        let three = try #require(
            try StashListParser.parse(listOutput([("On main: m", "")], parents: "\(shaB) \(shaB) \(shaB)")).first)
        let two = try #require(
            try StashListParser.parse(listOutput([("On main: m", "")], parents: "\(shaB) \(shaB)")).first)
        #expect(three.hasUntrackedParent)
        #expect(!two.hasUntrackedParent)
    }

    @Test func emptyOutputIsNoStashes() throws {
        #expect(try StashListParser.parse(Data()).isEmpty)
    }

    @Test func malformedOutputThrows() {
        let good = String(decoding: listOutput([("On main: m", "")]), as: UTF8.self)
        let badSha = good.replacingOccurrences(of: shaA, with: "nothex")
        let badDate = good.replacingOccurrences(of: date, with: "yesterday")
        for text in [good + "\0extra", "no leading separator", badSha, badDate] {
            #expect(throws: StashListParseError.self) { try StashListParser.parse(Data(text.utf8)) }
        }
    }
}
