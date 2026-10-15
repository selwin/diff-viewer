import Foundation
import Testing

@testable import DiffViewer

/// Runs the real `git` for the reads behind comparing two refs.
@Suite(.serialized) struct GitCompareCommandTests {
    @Test func refsListsBranchesRemotesAndTagsWithoutSymrefs() async throws {
        let repo = try await committedRepo()
        let commit = try await repo.git(["rev-parse", "HEAD"])
        let commitDate = try await repo.git(["show", "-s", "--format=%ct", "HEAD"])
        try await repo.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try await repo.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        // The tag object is newer than the commit; the ref must report the commit's date.
        try await repo.git(
            ["tag", "-a", "v1", "-m", "release"],
            extraEnvironment: ["GIT_COMMITTER_DATE": "2030-01-01T00:00:00Z"])

        let refs = try await repo.client.refs().sorted { $0.fullName < $1.fullName }

        #expect(refs.map(\.fullName) == ["refs/heads/main", "refs/remotes/origin/main", "refs/tags/v1"])
        #expect(refs.map(\.name) == ["main", "origin/main", "v1"])
        #expect(refs.map(\.kind) == [.local, .remote, .tag])
        #expect(refs.allSatisfy { $0.commitSHA == commit })
        #expect(refs.allSatisfy { $0.committedAt.timeIntervalSince1970 == TimeInterval(commitDate) })
    }

    @Test func mergeBaseIsTheForkPointAndNilWithoutOne() async throws {
        let repo = try await committedRepo()
        let fork = try await repo.git(["rev-parse", "HEAD"])
        try await repo.git(["switch", "-c", "feature"])
        let feature = try await repo.commit("On feature")
        try await repo.git(["switch", "main"])
        let main = try await repo.commit("On main")
        try await repo.git(["checkout", "--orphan", "unrelated"])
        let unrelated = try await repo.commit("Unrelated root")

        #expect(try await repo.client.mergeBase(feature, main) == fork)
        #expect(try await repo.client.mergeBase(main, unrelated) == nil)
    }

    @Test func churnCountsRenamesOnlyWhenContentIsIdentical() async throws {
        let repo = try await committedRepo(["old.txt": "one\ntwo\nthree\nfour\n"])
        let base = try await repo.git(["rev-parse", "HEAD"])
        try await repo.git(["mv", "old.txt", "new.txt"])
        let renamed = try await repo.commit("Rename")
        try repo.write("new.txt", "one\ntwo\nthree\nfour\nfive\n")
        let edited = try await repo.commit("Edit")

        #expect(
            try await repo.client.churn(base: base, target: renamed)
                == IncomingChangeSummary(fileCount: 1, addedLineCount: 0, deletedLineCount: 0))
        #expect(
            try await repo.client.churn(base: base, target: edited)
                == IncomingChangeSummary(fileCount: 2, addedLineCount: 5, deletedLineCount: 4))
    }
}
