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

        /// A fixed identity and none of the developer's own configuration, for the test
        /// process's git calls and for the client's alike.
        static let environment = [
            "GIT_AUTHOR_NAME": "Tester", "GIT_AUTHOR_EMAIL": "tester@example.com",
            "GIT_COMMITTER_NAME": "Tester", "GIT_COMMITTER_EMAIL": "tester@example.com",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "LC_ALL": "C",
        ]

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("DiffViewerGitTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            client = GitClient(repoRoot: url, environment: Self.environment, resolveCommitEnvironment: { [:] })
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        @discardableResult
        func git(_ arguments: [String], extraEnvironment: [String: String] = [:]) async throws -> String {
            let result = try await ProcessRunner.run(
                GitClient.executable,
                arguments: arguments,
                currentDirectory: url,
                environment: Self.environment.merging(extraEnvironment) { _, extra in extra }
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

        /// Local configuration a commit needs, with hooks pointed at an empty directory
        /// inside `.git` so the developer's own hooks never run and status stays clean.
        func prepareForCommits() async throws {
            try await git(["config", "user.name", "Tester"])
            try await git(["config", "user.email", "tester@example.com"])
            try await git(["config", "commit.gpgsign", "false"])
            let hooks = url.appendingPathComponent(".git/empty-hooks", isDirectory: true)
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            try await git(["config", "core.hooksPath", hooks.path])
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

    @Test func headStateNamesAnUnbornBranch() async throws {
        let repo = try Repo()
        try await repo.initialize()
        #expect(try await repo.client.headState() == .named("main"), "a branch with no commits yet")
    }

    @Test func headStateReportsTheDetachedCommit() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        let sha = try await repo.commit("Root commit")

        try await repo.git(["checkout", "--detach"])
        #expect(try await repo.client.headState() == .detached(sha: sha))

        try await repo.git(["checkout", "main"])
        #expect(try await repo.client.headState() == .named("main"))
    }

    /// `symbolic-ref --short` would answer `heads/main` here, to stay unambiguous with
    /// the tag, and that is not a branch name anyone wants in the window subtitle.
    @Test func headStateIgnoresATagNamedLikeTheBranch() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try await repo.git(["tag", "main"])

        #expect(try await repo.client.headState() == .named("main"))
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

    // MARK: File actions

    /// `git add` on a path that is gone records the deletion; nothing should be left
    /// unstaged afterwards.
    @Test func stageRecordsADeletion() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try repo.delete("a.txt")

        try await repo.client.perform(.stage, on: ["a.txt"])

        let files = try await repo.client.status()
        #expect(files.count == 1, "nothing should be left unstaged")
        #expect(files.first?.path == "a.txt")
        #expect(files.first?.kind == .deleted)
        #expect(files.first?.area == .staged)
    }

    /// Unstaging an add leaves the file on disk and unknown to git, not deleted.
    @Test func unstageReturnsAStagedAddToUntracked() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try repo.write("new.txt", "fresh\n")
        try await repo.git(["add", "new.txt"])

        try await repo.client.perform(.unstage, on: ["new.txt"])

        let files = try await repo.client.status()
        #expect(files.map(\.path) == ["new.txt"])
        #expect(files.first?.kind == .untracked)
        #expect(files.first?.area == .unstaged)
        #expect(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("new.txt").path))
    }

    /// Before the first commit there is no HEAD to restore the index from, and every
    /// staged file is a staged add. `git restore --staged` fails outright there
    /// ("fatal: could not resolve 'HEAD'"); `git reset` drops the index entry and leaves
    /// the file untracked on disk, which is what unstaging an add means anywhere else.
    @Test func unstageWorksInARepositoryWithNoCommits() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("new.txt", "fresh\n")
        try await repo.git(["add", "new.txt"])

        try await repo.client.perform(.unstage, on: ["new.txt"])

        let files = try await repo.client.status()
        #expect(files.map(\.path) == ["new.txt"])
        #expect(files.first?.kind == .untracked)
        #expect(files.first?.area == .unstaged)
        #expect(try Data(contentsOf: repo.url.appendingPathComponent("new.txt")) == Data("fresh\n".utf8))
    }

    @Test func discardRestoresADeletedFile() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try repo.delete("a.txt")

        try await repo.client.perform(.discard, on: ["a.txt"])

        let restored = try Data(contentsOf: repo.url.appendingPathComponent("a.txt"))
        #expect(restored == Data("one\n".utf8))
        #expect(try await repo.client.status().isEmpty)
    }

    /// `git restore` rewrites the worktree from the index, so a staged change survives:
    /// discarding throws away only what was never staged.
    @Test func discardOverAStagedChangeKeepsTheIndexVersion() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "a\n")
        try await repo.commit("Root commit")
        try repo.write("a.txt", "b\n")
        try await repo.git(["add", "a.txt"])
        try repo.write("a.txt", "c\n")

        try await repo.client.perform(.discard, on: ["a.txt"])

        #expect(try Data(contentsOf: repo.url.appendingPathComponent("a.txt")) == Data("b\n".utf8))
        let files = try await repo.client.status()
        #expect(files.map(\.path) == ["a.txt"])
        #expect(files.first?.area == .staged)
        #expect(files.first?.kind == .modified)
    }

    /// One git process for the whole batch: both paths reach `git add` after `--`, and
    /// both end up in the index.
    @Test func stageRecordsEveryPathInOneCall() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try repo.write("b.txt", "one\n")
        try await repo.commit("Root commit")
        try repo.write("a.txt", "two\n")
        try repo.write("b.txt", "two\n")

        try await repo.client.perform(.stage, on: ["a.txt", "b.txt"])

        let files = try await repo.client.status()
        #expect(files.map(\.path).sorted() == ["a.txt", "b.txt"], "nothing should be left unstaged")
        #expect(files.allSatisfy { $0.area == .staged })
    }

    /// An empty batch must not reach git: `git reset -q --` with no pathspec resets the
    /// whole index, so a caller that passes nothing would silently unstage everything.
    @Test func anEmptyBatchNeverReachesGit() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try repo.write("a.txt", "two\n")
        try await repo.git(["add", "a.txt"])

        try await repo.client.perform(.unstage, on: [])

        let files = try await repo.client.status()
        #expect(files.map(\.path) == ["a.txt"])
        #expect(files.first?.area == .staged, "an empty batch must leave the index alone")
    }

    @Test func trashRemovesTheFileFromTheWorktree() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("junk.txt", "throw me away\n")

        try await repo.client.trash(["junk.txt"])

        #expect(!FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("junk.txt").path))
        #expect(try await repo.client.status().isEmpty)
    }

    // MARK: Worktree reads

    /// The distinction the diff engine depends on: a missing file is a side that does not
    /// exist, and anything else is a failure. Reporting a read error as "missing" would
    /// draw a modified file as deleted.
    @Test func worktreeContentsIsNilOnlyForAMissingFile() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("there.txt", "one\n")

        #expect(try await repo.client.worktreeContents(of: "there.txt") == Data("one\n".utf8))
        #expect(try await repo.client.worktreeContents(of: "gone.txt") == nil)
    }

    @Test func worktreeContentsThrowsForAFileItCannotRead() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("secret.txt", "one\n")
        let secret = repo.url.appendingPathComponent("secret.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path) }

        await #expect(throws: (any Error).self) {
            try await repo.client.worktreeContents(of: "secret.txt")
        }
        // A directory where a file is expected is the other shape of "there, unreadable".
        try FileManager.default.createDirectory(
            at: repo.url.appendingPathComponent("adir"), withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) {
            try await repo.client.worktreeContents(of: "adir")
        }
    }

    /// The error alert shows the error's description, so git's own words have to reach it.
    /// Discard, not unstage: `git reset` accepts a pathspec that matches nothing and exits
    /// zero, so it is the wrong command to test a refusal with.
    @Test func aRefusedActionThrowsWithGitsStderr() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")

        await #expect(throws: (any Error).self) {
            try await repo.client.perform(.discard, on: ["missing.txt"])
        }
        do {
            try await repo.client.perform(.discard, on: ["missing.txt"])
            Issue.record("discarding an unknown path should fail")
        } catch {
            #expect(error.localizedDescription.contains("did not match"), "\(error.localizedDescription)")
            #expect(error.localizedDescription.contains("missing.txt"))
        }
    }
}
