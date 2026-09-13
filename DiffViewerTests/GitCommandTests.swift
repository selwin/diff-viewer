import Foundation
import Testing

@testable import DiffViewer

/// Runs the real `git` against repositories built for each test.
///
/// These exist because stubs cannot catch a command that is wrong: `git diff-tree`
/// given only a merge commit prints nothing at all, so a merge would have shown up as
/// an empty changeset with every unit test still green.
@Suite(.serialized) struct GitCommandTests {
    // MARK: Building repositories

    /// A repository in a temporary directory, deleted when the test finishes.
    final class Repo {
        let url: URL
        let client: GitClient

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("DiffViewerGitTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            client = GitClient(repoRoot: url)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        @discardableResult
        func git(_ arguments: [String]) async throws -> String {
            let result = try await ProcessRunner.run(
                GitClient.executable,
                arguments: arguments,
                currentDirectory: url,
                environment: [
                    "GIT_AUTHOR_NAME": "Tester", "GIT_AUTHOR_EMAIL": "tester@example.com",
                    "GIT_COMMITTER_NAME": "Tester", "GIT_COMMITTER_EMAIL": "tester@example.com",
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                    "LC_ALL": "C",
                ]
            )
            guard result.status == 0 else {
                throw ProcessError.failed(
                    command: "git " + arguments.joined(separator: " "), status: result.status,
                    stderr: result.stderrString)
            }
            return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func initialize() async throws {
            try await git(["init", "-b", "main"])
        }

        func write(_ path: String, _ contents: String) throws {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }

        func delete(_ path: String) throws {
            try FileManager.default.removeItem(at: url.appendingPathComponent(path))
        }

        @discardableResult
        func commit(_ subject: String) async throws -> String {
            try await git(["add", "-A"])
            try await git(["commit", "--allow-empty", "-m", subject])
            return try await git(["rev-parse", "HEAD"])
        }

        /// The ref the app would build for `sha`, with the parent git reports.
        func ref(_ sha: String) async throws -> CommitRef {
            let parents = try await git(["rev-list", "--parents", "-n", "1", sha])
                .split(separator: " ").map(String.init)
            return CommitRef(
                sha: sha, shortSha: try await git(["rev-parse", "--short", sha]),
                firstParentSHA: parents.count > 1 ? parents[1] : nil)
        }
    }

    /// A repository whose history is: root (two files), a commit on a side branch, and a
    /// merge of that branch into main.
    private func mergeRepo() async throws -> (repo: Repo, root: String, side: String, merge: String) {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("keep.txt", "one\ntwo\n")
        try repo.write("gone.txt", "bye\n")
        let root = try await repo.commit("Root commit")

        try await repo.git(["checkout", "-b", "side"])
        try repo.write("side.txt", "from the side\n")
        try repo.write("keep.txt", "one\ntwo\nthree\n")
        let side = try await repo.commit("Side commit")

        try await repo.git(["checkout", "main"])
        try repo.write("main.txt", "on main\n")
        try await repo.commit("Main commit")
        try await repo.git(["merge", "--no-ff", "side", "-m", "Merge side"])
        let merge = try await repo.git(["rev-parse", "HEAD"])
        return (repo, root, side, merge)
    }

    // MARK: Commit file lists

    /// The bug a stub cannot see: `git diff-tree <merge>` alone prints nothing, so this
    /// list would be empty and every merge would look like an empty commit.
    @Test func aMergeReportsItsFirstParentChanges() async throws {
        let (repo, _, _, merge) = try await mergeRepo()
        let files = try await repo.client.changedFiles(in: try await repo.ref(merge))
        #expect(!files.isEmpty, "a merge is not an empty changeset")

        let expected = try await repo.git(["diff", "--name-only", "--no-renames", "\(merge)^1", merge])
            .split(separator: "\n").map(String.init).sorted()
        #expect(files.map(\.path) == expected)
        #expect(files.contains { $0.path == "side.txt" && $0.kind == .added })
    }

    @Test func aRootCommitIsEveryFileAdded() async throws {
        let (repo, root, _, _) = try await mergeRepo()
        let ref = try await repo.ref(root)
        #expect(ref.firstParentSHA == nil)

        let files = try await repo.client.changedFiles(in: ref)
        #expect(files.map(\.path) == ["gone.txt", "keep.txt"])
        #expect(files.allSatisfy { $0.kind == .added })
    }

    @Test func anOrdinaryCommitReportsAddsModifiesAndDeletes() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("keep.txt", "one\n")
        try repo.write("gone.txt", "bye\n")
        try await repo.commit("Root commit")

        try repo.write("keep.txt", "one\ntwo\n")
        try repo.write("new.txt", "hello\n")
        try repo.delete("gone.txt")
        let sha = try await repo.commit("Second commit")

        let files = try await repo.client.changedFiles(in: try await repo.ref(sha))
        #expect(files.map(\.path) == ["gone.txt", "keep.txt", "new.txt"])
        #expect(files.map(\.kind) == [.deleted, .modified, .added])
    }

    // MARK: Line counts

    /// Compared against an explicit first-parent diff. `git show --numstat` prints
    /// nothing for a merge, so it would assert nothing at all here.
    @Test func commitNumstatMatchesTheFirstParentDiff() async throws {
        let (repo, _, _, merge) = try await mergeRepo()
        let entries = try await repo.client.numstat(area: .commit(try await repo.ref(merge)), ignoreWhitespace: false)
        #expect(!entries.isEmpty)

        let expected = try await repo.git(
            ["diff", "--numstat", "--no-renames", "\(merge)^1", merge, "--"])
        let rows =
            expected
            .split(separator: "\n")
            .map { line -> String in line.split(separator: "\t").map(String.init).joined(separator: " ") }
            .sorted()
        let actual =
            entries
            .map { entry -> String in
                guard case let .counted(added, deleted) = entry.stats else { return "\(entry.path) binary" }
                return "\(added) \(deleted) \(entry.path)"
            }
            .sorted()
        #expect(actual == rows)
    }

    @Test func rootCommitNumstatCountsEveryLineAsAdded() async throws {
        let (repo, root, _, _) = try await mergeRepo()
        let entries = try await repo.client.numstat(area: .commit(try await repo.ref(root)), ignoreWhitespace: false)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.stats) })
        #expect(byPath["keep.txt"] == .counted(added: 2, deleted: 0))
        #expect(byPath["gone.txt"] == .counted(added: 1, deleted: 0))
    }

    /// `-w` has to sit with the other flags: after the `--` that ends a commit's
    /// operands git would read it as a file name and report no changes at all.
    @Test func ignoringWhitespaceStillReportsACommitsChanges() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try repo.write("a.txt", "one\ntwo\n")
        let sha = try await repo.commit("Second commit")

        let ref = try await repo.ref(sha)
        let entries = try await repo.client.numstat(area: .commit(ref), ignoreWhitespace: true)
        #expect(entries.map(\.path) == ["a.txt"])
        #expect(entries.first?.stats == .counted(added: 1, deleted: 0))
    }

    // MARK: History

    @Test func recentCommitsParsesRealLogOutput() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try repo.write("a.txt", "two\n")
        // Separator bytes and a subject that is itself an object id: both are ordinary
        // content once the fields are NUL-framed and read positionally.
        try await repo.commit("Odd \u{1f} subject \u{1e} here")
        try repo.write("a.txt", "three\n")
        let hexSubject = String(repeating: "a", count: 40)
        let head = try await repo.commit(hexSubject)

        let commits = try await repo.client.recentCommits(startingAt: head, limit: 10)
        #expect(commits.map(\.subject) == [hexSubject, "Odd \u{1f} subject \u{1e} here", "Root commit"])
        #expect(commits.first?.ref.sha == head)
        #expect(commits.last?.ref.firstParentSHA == nil, "the root commit has no parent")
        #expect(commits.first?.ref.firstParentSHA == commits[1].ref.sha)
        #expect(commits.allSatisfy { $0.authorName == "Tester" })
    }

    @Test func recentCommitsFollowsFirstParentsOnly() async throws {
        let (repo, _, side, merge) = try await mergeRepo()
        let commits = try await repo.client.recentCommits(startingAt: merge, limit: 10)
        #expect(commits.first?.isMerge == true)
        #expect(!commits.contains { $0.ref.sha == side }, "side-branch commits are not listed individually")
    }

    @Test func recentCommitsHonoursTheLimit() async throws {
        let repo = try Repo()
        try await repo.initialize()
        for index in 0..<5 {
            try repo.write("a.txt", "line \(index)\n")
            try await repo.commit("Commit \(index)")
        }
        let head = try await repo.git(["rev-parse", "HEAD"])
        #expect(try await repo.client.recentCommits(startingAt: head, limit: 3).count == 3)
    }

    // MARK: HEAD

    @Test func headShaResolvesAndReportsAnUnbornBranchAsNil() async throws {
        let repo = try Repo()
        try await repo.initialize()
        #expect(try await repo.client.headSha() == nil, "a branch with no commits yet")

        try repo.write("a.txt", "one\n")
        let sha = try await repo.commit("Root commit")
        #expect(try await repo.client.headSha() == sha)
    }

    /// A repository whose HEAD points at a malformed ref must not read as "no commits
    /// yet": `symbolic-ref` exits non-zero for it, so it reaches the throw.
    @Test func headShaThrowsForADamagedRef() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try Data("not-a-sha-at-all\n".utf8).write(to: repo.url.appendingPathComponent(".git/refs/heads/main"))

        await #expect(throws: (any Error).self) { try await repo.client.headSha() }
    }

    @Test func headShaThrowsOutsideARepository() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DiffViewerNotARepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: (any Error).self) {
            try await GitClient(repoRoot: directory).headSha()
        }
    }

    // MARK: Contents

    @Test func contentsReadsAGivenRevisionAndThrowsForAMissingOne() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "first\n")
        let first = try await repo.commit("Root commit")
        try repo.write("a.txt", "second\n")
        let second = try await repo.commit("Second commit")

        #expect(try await repo.client.contents(of: "a.txt", at: first) == Data("first\n".utf8))
        #expect(try await repo.client.contents(of: "a.txt", at: second) == Data("second\n".utf8))

        // Git describes an unreadable revision as though the path were missing. Being
        // lenient here would render an unreachable commit as a file added wholesale.
        await #expect(throws: (any Error).self) {
            try await repo.client.contents(of: "a.txt", at: String(repeating: "0", count: 40))
        }
    }
}
