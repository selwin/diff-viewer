import Foundation
import Testing

@testable import DiffViewer

/// Runs the real `git` for a range: the target's changes since its merge base.
@Suite(.serialized) struct GitRangeCommandTests {
    private struct Fixture {
        let repo: GitCommandTests.Repo
        let root: String
        /// The first `feature` commit.
        let mid: String
        let tip: String

        func range(from base: String) -> CommitRange {
            CommitRange(baseName: "main", targetName: "feature", mergeBaseSHA: base, targetSHA: tip)
        }
    }

    /// `main` has a, b and f. `feature` edits a twice and adds c, then renames b to d
    /// exactly and moves f to g with an edit. `main` then adds e.
    private func fixture() async throws -> Fixture {
        let repo = try await committedRepo([
            "a.txt": "a1\na2\na3\n", "b.txt": "bee\nbee\n", "f.txt": "f1\nf2\nf3\nf4\n",
        ])
        let root = try await repo.git(["rev-parse", "HEAD"])
        try await repo.git(["switch", "-c", "feature"])
        try repo.write("a.txt", "a1\nA2\na3\n")
        try repo.write("c.txt", "c1\nc2\n")
        let mid = try await repo.commit("Edit a, add c")
        try repo.write("a.txt", "a1\nA2\nA3\n")
        try await repo.git(["mv", "b.txt", "d.txt"])
        try repo.delete("f.txt")
        try repo.write("g.txt", "f1\nf2\nf3\nf4\nf5\n")
        let tip = try await repo.commit("Rename b, move f")
        try await repo.git(["switch", "main"])
        try repo.write("e.txt", "e1\n")
        try await repo.commit("Add e on main")
        return Fixture(repo: repo, root: root, mid: mid, tip: tip)
    }

    @Test func rangeListsTheTargetsChangesSinceTheMergeBase() async throws {
        let fixture = try await fixture()
        let range = fixture.range(from: fixture.root)

        let files = try await fixture.repo.client.changedFiles(in: range)
        let listed = files.map { "\($0.kind.rawValue) \($0.originalPath.map { "\($0) → " } ?? "")\($0.path)" }
        #expect(listed.sorted() == ["A c.txt", "A g.txt", "D f.txt", "M a.txt", "R b.txt → d.txt"])
        #expect(files.allSatisfy { $0.area == .range(range) })
    }

    @Test func rangeCountsTheTargetsChangesSinceTheMergeBase() async throws {
        let fixture = try await fixture()
        let range = fixture.range(from: fixture.root)

        let counts = try await fixture.repo.client.numstat(area: .range(range), ignoreWhitespace: false)
        let byPath = Dictionary(uniqueKeysWithValues: counts.map { ($0.path, $0.stats) })
        #expect(
            byPath == [
                "a.txt": .counted(added: 2, deleted: 2), "c.txt": .counted(added: 2, deleted: 0),
                "d.txt": .counted(added: 0, deleted: 0), "f.txt": .counted(added: 0, deleted: 4),
                "g.txt": .counted(added: 5, deleted: 0),
            ])
    }

    /// The same target from two merge bases: each file is its own, and reads its own base.
    @Test func eachMergeBaseIsItsOwnFileAndReadsItsOwnOldSide() async throws {
        let fixture = try await fixture()
        let fromRoot = try await fixture.repo.client.changedFiles(in: fixture.range(from: fixture.root))
        let fromMid = try await fixture.repo.client.changedFiles(in: fixture.range(from: fixture.mid))
        let rootA = try #require(fromRoot.first { $0.path == "a.txt" })
        let midA = try #require(fromMid.first { $0.path == "a.txt" })
        #expect(rootA.id != midA.id)

        let rootSources = try await DiffEngine.sources(for: rootA, client: fixture.repo.client)
        #expect(rootSources.old == Data("a1\na2\na3\n".utf8))
        #expect(rootSources.new == Data("a1\nA2\nA3\n".utf8))
        let midSources = try await DiffEngine.sources(for: midA, client: fixture.repo.client)
        #expect(midSources.old == Data("a1\nA2\na3\n".utf8))
        #expect(midSources.new == Data("a1\nA2\nA3\n".utf8))
    }

    /// Names are display only: a range is its two SHAs, and never a commit's identity.
    @Test func rangeIdentityIsItsShas() {
        let base = objectID("base")
        let target = objectID("target")
        let first = CommitRange(baseName: "main", targetName: "feature", mergeBaseSHA: base, targetSHA: target)
        let renamed = CommitRange(
            baseName: "origin/main", targetName: "v2", mergeBaseSHA: base, targetSHA: target)
        #expect(first == renamed)
        #expect(first.hashValue == renamed.hashValue)
        #expect(changedFile("a.txt", area: .range(first)).id == changedFile("a.txt", area: .range(renamed)).id)

        let commit = CommitRef(sha: target, shortSha: String(target.prefix(7)), firstParentSHA: base)
        #expect(ChangedFile.Area.range(first).identity != ChangedFile.Area.commit(commit).identity)
    }
}
