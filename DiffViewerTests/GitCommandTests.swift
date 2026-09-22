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
            client = GitClient(repoRoot: url, environment: Self.environment, resolveHookEnvironment: { [:] })
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

        /// `environment` is merged over the fixture's fixed identity for the commit call
        /// alone, so a test can pin a `GIT_COMMITTER_DATE` per commit.
        @discardableResult
        func commit(_ subject: String, environment: [String: String] = [:]) async throws -> String {
            try await git(["add", "-A"])
            try await git(["commit", "--allow-empty", "-m", subject], extraEnvironment: environment)
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
    }

    /// The list is in git's first-parent traversal order, not sorted by date: committer
    /// dates can run backwards (rebases, clock skew) and each is reported as stamped.
    @Test func recentCommitsKeepTraversalOrderAndCommitterDates() async throws {
        let repo = try Repo()
        try await repo.initialize()
        let stamps = ["2026-09-19T10:00:00+00:00", "2026-09-17T10:00:00+00:00", "2026-09-18T10:00:00+00:00"]
        var shas: [String] = []
        for (index, stamp) in stamps.enumerated() {
            try repo.write("a.txt", "line \(index)\n")
            shas.append(try await repo.commit("Commit \(index)", environment: ["GIT_COMMITTER_DATE": stamp]))
        }

        let commits = try await repo.client.recentCommits(startingAt: shas[2], limit: 10)
        #expect(commits.map(\.ref.sha) == shas.reversed())
        let iso = ISO8601DateFormatter()
        #expect(commits.map(\.committedAt) == stamps.reversed().map { iso.date(from: $0) })
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

    // MARK: Branches

    /// A repository with one commit on `main` and a `side` branch whose `file.txt` differs.
    private func twoBranchRepo() async throws -> Repo {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("file.txt", "main\n")
        try await repo.commit("Root commit")
        try await repo.git(["checkout", "-b", "side"])
        try repo.write("file.txt", "side\n")
        try await repo.commit("Side commit")
        try await repo.git(["checkout", "main"])
        return repo
    }

    /// Installs `script` as `post-checkout` in a hooks directory of its own and points the
    /// repository at it, the way the commit hook test does.
    private func installPostCheckoutHook(_ script: String, in repo: Repo) async throws {
        let hooks = repo.url.appendingPathComponent(".git/test-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("post-checkout")
        try Data(script.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try await repo.git(["config", "core.hooksPath", hooks.path])
    }

    /// `%(refname:short)` would answer `heads/main` here, to stay unambiguous with the
    /// tag, and that is not a branch name anyone wants in the picker.
    @Test func localBranchesListsHeadsWithoutThePrefix() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try await repo.git(["branch", "zeta"])
        try await repo.git(["branch", "feature/x"])
        try await repo.git(["tag", "main"])

        #expect(try await repo.client.localBranches().map(\.name) == ["feature/x", "main", "zeta"])
    }

    /// git allows a Unicode line separator inside a ref name and a non-breaking space at
    /// its end; splitting on `isNewline` or trimming whitespace would corrupt both.
    @Test func branchNamesWithUnicodeSeparatorsRoundTrip() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        let names = ["a\u{2028}b", "nbsp\u{00A0}"]
        for name in names {
            try await repo.git(["branch", name])
        }

        let listed = try await repo.client.localBranches().map(\.name)
        for name in names {
            #expect(listed.contains(name))
            try await repo.client.switchBranch(to: name)
            #expect(try await repo.client.headState() == .named(name))
        }
    }

    @Test func localBranchesOfAnUnbornRepositoryIsEmpty() async throws {
        let repo = try Repo()
        try await repo.initialize()
        #expect(try await repo.client.localBranches().isEmpty)
    }

    /// The counts come from the remote-tracking ref, so a commit made after pushing
    /// reads as one ahead with no fetch of any kind.
    @Test func localBranchesReportsAheadOfTheUpstream() async throws {
        let (repo, remote) = try await pushedRepo()
        try repo.write("b.txt", "two\n")
        try await repo.commit("Second commit")

        let main = try #require(try await repo.client.localBranches().first { $0.name == "main" })
        #expect(main.upstream?.shortName == "origin/main")
        #expect(main.upstream?.tracking == .counts(ahead: 1, behind: 0))
        // The fixture deletes its directory when it goes: keep it until the reads are done.
        _ = remote
    }

    /// Deleting the remote-tracking ref is what a pruned remote branch leaves behind.
    @Test func localBranchesReportsAGoneUpstream() async throws {
        let (repo, remote) = try await pushedRepo()
        try await repo.git(["update-ref", "-d", "refs/remotes/origin/main"])

        let main = try #require(try await repo.client.localBranches().first { $0.name == "main" })
        #expect(main.upstream?.shortName == "origin/main")
        #expect(main.upstream?.tracking == .gone)
        _ = remote
    }

    /// A repository with one commit pushed to a bare remote, so `main` tracks
    /// `origin/main` and is in sync.
    private func pushedRepo() async throws -> (repo: Repo, remote: Repo) {
        let remote = try Repo()
        try await remote.git(["init", "--bare"])

        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try await repo.git(["remote", "add", "origin", remote.url.path])
        try await repo.git(["push", "-u", "origin", "main"])
        return (repo, remote)
    }

    /// A second working clone of the same bare remote, so a test can push from one side
    /// and fetch or pull from the other. Every remote here is a local path: nothing in
    /// these tests goes over a network.
    private func clone(of remote: Repo) async throws -> Repo {
        let clone = try Repo()
        try await clone.git(["clone", remote.url.path, "."])
        try await clone.prepareForCommits()
        return clone
    }

    // MARK: Remotes

    @Test func remoteNamesListsConfiguredRemotes() async throws {
        let bare = try Repo()
        try await bare.initialize()
        #expect(try await bare.client.remoteNames().isEmpty)

        let (repo, remote) = try await pushedRepo()
        #expect(try await repo.client.remoteNames() == ["origin"])
        _ = remote
    }

    @Test func fetchUpdatesTheBehindCount() async throws {
        let (repo, remote) = try await pushedRepo()
        let other = try await clone(of: remote)
        try other.write("b.txt", "two\n")
        try await other.commit("Clone commit")
        try await other.git(["push", "origin", "main"])

        let before = try #require(try await repo.client.localBranches().first { $0.name == "main" })
        #expect(before.upstream?.tracking == .counts(ahead: 0, behind: 0), "no fetch yet")

        try await repo.client.fetch(remote: "origin")

        let after = try #require(try await repo.client.localBranches().first { $0.name == "main" })
        #expect(after.upstream?.tracking == .counts(ahead: 0, behind: 1))
    }

    /// Pruning is configurable, and a reader's fetch must never be the thing that deletes
    /// a ref or a tag out from under them.
    @Test func fetchNeverPrunes() async throws {
        let (repo, remote) = try await pushedRepo()
        try await repo.git(["config", "fetch.prune", "true"])
        try await repo.git(["config", "fetch.pruneTags", "true"])
        try await repo.git(["config", "--add", "remote.origin.fetch", "refs/tags/*:refs/tags/*"])
        try await repo.git(["tag", "local-only"])
        let stale = try await repo.git(["rev-parse", "HEAD"])
        try await repo.git(["update-ref", "refs/remotes/origin/stale", stale])

        try await repo.client.fetch(remote: "origin")

        #expect(try await repo.git(["rev-parse", "--verify", "refs/tags/local-only"]) != "")
        #expect(try await repo.git(["rev-parse", "--verify", "refs/remotes/origin/stale"]) == stale)
        _ = remote
    }

    /// The counts compare against whatever ref the remote's mappings put the upstream in,
    /// so the fetch has to refresh that ref rather than a guessed `refs/remotes/origin/*`.
    @Test func fetchRefreshesANonstandardUpstreamMapping() async throws {
        let (repo, remote) = try await pushedRepo()
        try await repo.git([
            "config", "--replace-all", "remote.origin.fetch", "+refs/heads/*:refs/remotes/company/*",
        ])
        try await repo.git(["config", "branch.main.remote", "origin"])
        try await repo.git(["config", "branch.main.merge", "refs/heads/main"])

        let other = try await clone(of: remote)
        try other.write("b.txt", "two\n")
        try await other.commit("Clone commit")
        try await other.git(["push", "origin", "main"])

        try await repo.client.fetch(remote: "origin")

        let main = try #require(try await repo.client.localBranches().first { $0.name == "main" })
        #expect(main.upstream?.shortName == "company/main")
        #expect(main.upstream?.tracking == .counts(ahead: 0, behind: 1))
    }

    @Test func fetchFromAMissingRemoteThrows() async throws {
        let (repo, remote) = try await pushedRepo()
        try FileManager.default.removeItem(at: remote.url)

        await #expect(throws: (any Error).self) {
            try await repo.client.fetch(remote: "origin")
        }
    }

    /// Git would read the name as an option rather than a remote.
    @Test func fetchRejectsARemoteNameThatLooksLikeAnOption() async throws {
        let (repo, remote) = try await pushedRepo()
        await #expect(throws: (any Error).self) {
            try await repo.client.fetch(remote: "--all")
        }
        _ = remote
    }

    @Test func pullFastForwards() async throws {
        let (repo, remote) = try await pushedRepo()
        let other = try await clone(of: remote)
        try other.write("b.txt", "two\n")
        try await other.commit("Clone commit")
        try await other.git(["push", "origin", "main"])
        let tip = try await other.git(["rev-parse", "HEAD"])

        try await repo.client.pull()

        #expect(try await repo.git(["rev-parse", "HEAD"]) == tip)
        #expect(try Data(contentsOf: repo.url.appendingPathComponent("b.txt")) == Data("two\n".utf8))
    }

    /// `--no-edit` is a merge option; the rebase path has to keep working with it passed.
    @Test func pullUnderRebaseConfigWorks() async throws {
        let (repo, remote) = try await pushedRepo()
        try await repo.git(["config", "pull.rebase", "true"])
        let other = try await clone(of: remote)
        try other.write("remote.txt", "theirs\n")
        try await other.commit("Clone commit")
        try await other.git(["push", "origin", "main"])

        try repo.write("local.txt", "mine\n")
        try await repo.commit("Local commit")

        try await repo.client.pull()

        let parents = try await repo.git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ")
        #expect(parents.count == 2, "a rebase leaves linear history, not a merge")
        #expect(try await repo.git(["rev-list", "--count", "HEAD"]) == "3")
    }

    /// `pull.rebase=interactive` would open the sequence editor and wait. The pull must
    /// fail at once instead, and git aborts the rebase before touching the branch.
    @Test func interactiveRebasePullFailsPromptlyAndLeavesTheBranchAlone() async throws {
        let (repo, remote) = try await pushedRepo()
        try await repo.git(["config", "pull.rebase", "interactive"])
        let other = try await clone(of: remote)
        try other.write("remote.txt", "theirs\n")
        try await other.commit("Clone commit")
        try await other.git(["push", "origin", "main"])

        try repo.write("local.txt", "mine\n")
        try await repo.commit("Local commit")
        let head = try await repo.git(["rev-parse", "HEAD"])

        let error = await #expect(throws: ProcessError.self) { try await repo.client.pull() }
        #expect(error?.localizedDescription.contains("interactive rebase") == true)
        #expect(try await repo.git(["rev-parse", "HEAD"]) == head)
        #expect(!FileManager.default.fileExists(atPath: repo.url.appendingPathComponent(".git/rebase-merge").path))
    }

    /// A conflicted merge leaves the repository mid-merge, and the caller has to see the
    /// failure rather than a pull that looks done.
    @Test func conflictingPullThrowsAndLeavesMergeState() async throws {
        let (repo, remote) = try await pushedRepo()
        try await repo.git(["config", "pull.rebase", "false"])
        let other = try await clone(of: remote)
        try other.write("a.txt", "theirs\n")
        try await other.commit("Clone commit")
        try await other.git(["push", "origin", "main"])

        try repo.write("a.txt", "mine\n")
        try await repo.commit("Local commit")

        await #expect(throws: (any Error).self) { try await repo.client.pull() }
        #expect(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent(".git/MERGE_HEAD").path))
    }

    /// `push.default=matching` would send every branch that exists on both sides. The
    /// explicit refspec is what keeps a push to one branch from moving another.
    @Test func pushPushesOnlyTheNamedBranch() async throws {
        let (repo, remote) = try await pushedRepo()
        try await repo.git(["config", "push.default", "matching"])
        try await repo.git(["branch", "feature"])
        try await repo.git(["push", "origin", "feature"])
        let featureBefore = try await remote.git(["rev-parse", "refs/heads/feature"])

        try await repo.git(["checkout", "feature"])
        try repo.write("feature.txt", "f\n")
        try await repo.commit("Feature commit")
        try await repo.git(["checkout", "main"])
        try repo.write("main.txt", "m\n")
        let mainTip = try await repo.commit("Main commit")

        try await repo.client.push(branch: "main", to: "origin", remoteRef: "refs/heads/main")

        #expect(try await remote.git(["rev-parse", "refs/heads/main"]) == mainTip)
        #expect(try await remote.git(["rev-parse", "refs/heads/feature"]) == featureBefore)
    }

    /// A `+` in `remote.<name>.push` forces only the refspec it applies to; naming the
    /// refspec on the command line leaves that configuration out of it.
    @Test func pushIgnoresAForceRefspecInConfig() async throws {
        let (repo, remote) = try await pushedRepo()
        try await repo.git(["config", "remote.origin.push", "+refs/heads/*:refs/heads/*"])
        try repo.write("b.txt", "two\n")
        try await repo.commit("Second commit")
        try await repo.git(["push", "origin", "main"])
        let remoteTip = try await remote.git(["rev-parse", "refs/heads/main"])

        // A rewritten history: the remote tip is no longer an ancestor of ours.
        try await repo.git(["reset", "--hard", "HEAD~1"])
        try repo.write("c.txt", "three\n")
        try await repo.commit("Rewritten commit")

        do {
            try await repo.client.push(branch: "main", to: "origin", remoteRef: "refs/heads/main")
            Issue.record("a non-fast-forward push should be rejected")
        } catch {
            #expect(error.localizedDescription.contains("rejected"), "\(error.localizedDescription)")
        }
        #expect(try await remote.git(["rev-parse", "refs/heads/main"]) == remoteTip)
    }

    /// `push.followTags=true` would send annotated tags along with the branch; a viewer's
    /// push publishes the branch and nothing else.
    @Test func pushLeavesTagsBehind() async throws {
        let (repo, remote) = try await pushedRepo()
        try await repo.git(["config", "push.followTags", "true"])
        try repo.write("b.txt", "two\n")
        let tip = try await repo.commit("Second commit")
        try await repo.git(["tag", "-a", "v1", "-m", "Version 1"])

        try await repo.client.push(branch: "main", to: "origin", remoteRef: "refs/heads/main")

        #expect(try await remote.git(["rev-parse", "refs/heads/main"]) == tip)
        await #expect(throws: (any Error).self) {
            try await remote.git(["rev-parse", "--verify", "refs/tags/v1"])
        }
    }

    @Test func pushBehindTheUpstreamIsRejected() async throws {
        let (repo, remote) = try await pushedRepo()
        let other = try await clone(of: remote)
        try other.write("b.txt", "two\n")
        try await other.commit("Clone commit")
        try await other.git(["push", "origin", "main"])
        let remoteTip = try await remote.git(["rev-parse", "refs/heads/main"])

        await #expect(throws: (any Error).self) {
            try await repo.client.push(branch: "main", to: "origin", remoteRef: "refs/heads/main")
        }
        #expect(try await remote.git(["rev-parse", "refs/heads/main"]) == remoteTip)
    }

    /// Git would read either name as an option rather than a branch or a remote.
    @Test func pushRejectsANameThatLooksLikeAnOption() async throws {
        let (repo, remote) = try await pushedRepo()
        await #expect(throws: (any Error).self) {
            try await repo.client.push(branch: "--mirror", to: "origin", remoteRef: "refs/heads/main")
        }
        await #expect(throws: (any Error).self) {
            try await repo.client.push(branch: "main", to: "--mirror", remoteRef: "refs/heads/main")
        }
        _ = remote
    }

    /// The tip date orders the picker and the remote ref is what a push names, so both
    /// have to survive the round trip through `for-each-ref`.
    @Test func localBranchesCarryTipDatesAndUpstreamRefs() async throws {
        let (repo, remote) = try await pushedRepo()
        let stamp = "2026-09-19T10:00:00+00:00"
        try repo.write("b.txt", "two\n")
        try await repo.commit("Dated commit", environment: ["GIT_COMMITTER_DATE": stamp])

        let main = try #require(try await repo.client.localBranches().first { $0.name == "main" })
        #expect(main.tipCommittedAt == ISO8601DateFormatter().date(from: stamp))
        #expect(main.upstream?.remote == "origin")
        #expect(main.upstream?.remoteRef == "refs/heads/main")
        _ = remote
    }

    @Test func switchBranchMovesHead() async throws {
        let repo = try await twoBranchRepo()
        try await repo.client.switchBranch(to: "side")
        #expect(try await repo.client.headState() == .named("side"))
    }

    @Test func switchBranchFromDetachedHeadReattaches() async throws {
        let repo = try await twoBranchRepo()
        try await repo.git(["checkout", "--detach"])
        try await repo.client.switchBranch(to: "main")
        #expect(try await repo.client.headState() == .named("main"))
    }

    @Test func switchBranchToAnUnknownNameThrows() async throws {
        let repo = try await twoBranchRepo()
        await #expect(throws: (any Error).self) {
            try await repo.client.switchBranch(to: "nowhere")
        }
        #expect(try await repo.client.headState() == .named("main"))
    }

    /// Git refuses to overwrite an uncommitted edit, and the refusal leaves both HEAD and
    /// the edit exactly where they were.
    @Test func switchBranchRefusesConflictingLocalChanges() async throws {
        let repo = try await twoBranchRepo()
        try repo.write("file.txt", "edited on main\n")

        await #expect(throws: (any Error).self) {
            try await repo.client.switchBranch(to: "side")
        }
        #expect(try await repo.client.headState() == .named("main"))
        #expect(try Data(contentsOf: repo.url.appendingPathComponent("file.txt")) == Data("edited on main\n".utf8))
    }

    /// Without `--no-guess`, `git switch feature` would quietly create a local `feature`
    /// tracking `origin/feature`. A stale menu entry must not do that.
    @Test func switchBranchNeverCreatesATrackingBranch() async throws {
        let remote = try Repo()
        try await remote.initialize()
        try remote.write("a.txt", "one\n")
        try await remote.commit("Root commit")
        try await remote.git(["branch", "feature"])

        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try await repo.git(["remote", "add", "origin", remote.url.path])
        try await repo.git(["fetch", "origin"])
        #expect(try await repo.git(["rev-parse", "--verify", "refs/remotes/origin/feature"]) != "")

        await #expect(throws: (any Error).self) {
            try await repo.client.switchBranch(to: "feature")
        }
        #expect(try await repo.client.localBranches().map(\.name) == ["main"])
        #expect(try await repo.client.headState() == .named("main"))
    }

    /// Git would read the name as an option rather than a branch.
    @Test func switchBranchRejectsANameThatLooksLikeAnOption() async throws {
        let repo = try await twoBranchRepo()
        await #expect(throws: (any Error).self) {
            try await repo.client.switchBranch(to: "-c")
        }
        #expect(try await repo.client.localBranches().map(\.name) == ["main", "side"])
        #expect(try await repo.client.headState() == .named("main"))
    }

    /// A post-checkout hook sees the login shell's PATH, and a caller's own overrides still
    /// beat it, the same as a commit hook.
    @Test func switchBranchHooksSeeTheInjectedEnvironment() async throws {
        let repo = try await twoBranchRepo()
        let probe = repo.url.appendingPathComponent(".git/probe.txt")
        try await installPostCheckoutHook(
            """
            #!/bin/sh
            printf '%s\\n%s\\n' "$PATH" "$DIFFVIEWER_HOOK" > "$DIFFVIEWER_HOOK_FILE"

            """, in: repo)

        let resolvedPath = "/hook/path:/usr/bin:/bin"
        let client = GitClient(
            repoRoot: repo.url,
            environment: Repo.environment.merging(
                ["DIFFVIEWER_HOOK": "override", "DIFFVIEWER_HOOK_FILE": probe.path]
            ) { $1 },
            resolveHookEnvironment: { ["PATH": resolvedPath, "DIFFVIEWER_HOOK": "resolved"] }
        )

        try await client.switchBranch(to: "side")

        let lines = try String(contentsOf: probe, encoding: .utf8).split(separator: "\n").map(String.init)
        // Git puts its own exec path in front of PATH for hooks, so the tail is what was handed in.
        #expect(lines.count == 2, "\(lines)")
        #expect(lines.first?.hasSuffix(":" + resolvedPath) == true, "\(lines)")
        #expect(lines.last == "override", "\(lines)")
    }

    /// A post-checkout hook runs after HEAD has moved and cannot undo it; its exit status
    /// becomes git's, so the switch both happened and threw, with the hook's own words.
    @Test func aFailingPostCheckoutHookThrowsWithHeadAlreadyMoved() async throws {
        let repo = try await twoBranchRepo()
        try await installPostCheckoutHook(
            """
            #!/bin/sh
            echo 'hook says no'
            exit 1

            """, in: repo)

        do {
            try await repo.client.switchBranch(to: "side")
            Issue.record("a failing post-checkout hook should fail the switch")
        } catch {
            #expect(error.localizedDescription.contains("hook says no"), "\(error.localizedDescription)")
        }
        #expect(try await repo.client.headState() == .named("side"))
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

    // MARK: Object sizes

    /// Every spec shape the joiner sends, in one batch: git answers each in order and
    /// says `missing` for the ones it cannot resolve, exit 0.
    @Test func objectSizesAnswerEverySpecInOrder() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "twelve bytes\n")
        let sha = try await repo.commit("Root commit")
        let oid = try await repo.git(["rev-parse", "HEAD:a.txt"])

        let sizes = try await repo.client.objectSizes(of: [
            oid, "HEAD:a.txt", ":a.txt", "\(sha):missing", String(repeating: "0", count: 40),
        ])
        #expect(sizes == [13, 13, 13, nil, nil])
    }

    @Test func objectSizesOfNothingNeverReachesGit() async throws {
        let client = GitClient(repoRoot: URL(fileURLWithPath: "/nonexistent"), environment: Repo.environment)
        #expect(try await client.objectSizes(of: []) == [])
    }

    /// The batch is line-framed, so a newline inside a spec would shift every later answer.
    @Test func objectSizesRejectsASpecWithANewline() async throws {
        let repo = try Repo()
        try await repo.initialize()
        await #expect(throws: (any Error).self) {
            try await repo.client.objectSizes(of: ["HEAD:a\nb.txt"])
        }
    }

    @Test func objectSizesRejectsASpecWithACRLF() async throws {
        let repo = try Repo()
        try await repo.initialize()
        await #expect(throws: (any Error).self) {
            try await repo.client.objectSizes(of: ["HEAD:a\r\nb.txt"])
        }
    }

    /// Git strips a CR before the terminator, so "image.png\r" would be sized as "image.png"
    /// with a correct answer count: only the pre-check can catch it.
    @Test func objectSizesRejectsASpecEndingInACR() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("image.png", "abc")
        try repo.write("image.png\r", "abcdefg")
        _ = try await repo.commit("Two names")
        #expect(try await repo.client.objectSizes(of: ["HEAD:image.png"]) == [3])
        await #expect(throws: (any Error).self) {
            try await repo.client.objectSizes(of: ["HEAD:image.png\r"])
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

    // MARK: Fingerprints

    /// A repository with one committed file and an unstaged edit to it.
    private func editedRepo() async throws -> Repo {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try repo.write("a.txt", "two\n")
        return repo
    }

    private func fingerprint(_ path: String, area: ChangedFile.Area, in repo: Repo) async throws
        -> DiffInputFingerprint?
    {
        try await repo.client.status().first { $0.path == path && $0.area == area }?.fingerprint
    }

    @Test func statusFingerprintsAreKnown() async throws {
        let repo = try await editedRepo()
        try repo.write("new.txt", "fresh\n")
        try await repo.git(["add", "new.txt"])

        let unstaged = try #require(try await fingerprint("a.txt", area: .unstaged, in: repo))
        #expect(unstaged.isKnown)
        guard case .file = unstaged.worktree else {
            Issue.record("expected a stat, got \(unstaged.worktree)")
            return
        }
        let staged = try #require(try await fingerprint("new.txt", area: .staged, in: repo))
        #expect(staged.isKnown)
        #expect(staged.old == .absent)
        #expect(staged.worktree == .notApplicable)
        let again = try await fingerprint("a.txt", area: .unstaged, in: repo)
        #expect(!DiffInputFingerprint.mayHaveChanged(unstaged, again), "nothing moved between two status calls")
    }

    @Test func anEditMovesTheFingerprint() async throws {
        let repo = try await editedRepo()
        let before = try await fingerprint("a.txt", area: .unstaged, in: repo)
        // The write changes the size and the mtime, and both are in the stat.
        try repo.write("a.txt", "two\nthree\n")
        let after = try await fingerprint("a.txt", area: .unstaged, in: repo)
        #expect(DiffInputFingerprint.mayHaveChanged(before, after))
    }

    /// The case an mtime-only check would miss: same size, mtime put back. `utimes`
    /// itself bumps ctime, so the stat still moves.
    @Test func aSameSizeEditWithRestoredMtimeMovesTheFingerprint() async throws {
        let repo = try await editedRepo()
        let file = repo.url.appendingPathComponent("a.txt")
        let before = try #require(try await fingerprint("a.txt", area: .unstaged, in: repo))
        let originalDate = try #require(
            try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)

        try repo.write("a.txt", "TWO\n")
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)

        let after = try #require(try await fingerprint("a.txt", area: .unstaged, in: repo))
        guard case let .file(_, ctimeBefore, sizeBefore, _) = before.worktree,
            case let .file(_, ctimeAfter, sizeAfter, _) = after.worktree
        else {
            Issue.record("expected stats, got \(before.worktree) and \(after.worktree)")
            return
        }
        #expect(sizeBefore == sizeAfter, "the edit is the same size on purpose")
        #expect(ctimeBefore != ctimeAfter, "restoring the mtime is itself a change to the inode")
        #expect(DiffInputFingerprint.mayHaveChanged(before, after))
    }

    /// `git add` leaves the file alone and writes a new blob, so the staged entry's index
    /// side differs from its HEAD side, and a later unstaged entry reads from that blob.
    @Test func stagingMovesTheIndexBlob() async throws {
        let repo = try await editedRepo()
        let unstagedBefore = try #require(try await fingerprint("a.txt", area: .unstaged, in: repo))

        try await repo.git(["add", "a.txt"])
        let staged = try #require(try await fingerprint("a.txt", area: .staged, in: repo))
        #expect(staged.old == unstagedBefore.old, "HEAD's blob was the index blob before the add")
        #expect(staged.new != staged.old)
        guard case .object = staged.new else {
            Issue.record("expected an index blob, got \(staged.new)")
            return
        }

        try repo.write("a.txt", "three\n")
        let unstagedAfter = try #require(try await fingerprint("a.txt", area: .unstaged, in: repo))
        #expect(unstagedAfter.old == staged.new, "the unstaged diff now reads the new index blob")
        #expect(DiffInputFingerprint.mayHaveChanged(unstagedBefore, unstagedAfter))
    }

    @Test func aDeletedWorktreeFileIsMissing() async throws {
        let repo = try await editedRepo()
        try repo.delete("a.txt")
        let deleted = try #require(try await fingerprint("a.txt", area: .unstaged, in: repo))
        #expect(deleted.kind == .deleted)
        #expect(deleted.worktree == .missing)
        #expect(deleted.isKnown)
    }

    /// The stat follows the link because the diff reads the target's contents, so an edit
    /// to the target changes what the link's diff shows.
    @Test func aSymlinkFingerprintFollowsItsTarget() async throws {
        let repo = try Repo()
        try await repo.initialize()
        try repo.write("target.txt", "one\n")
        try FileManager.default.createSymbolicLink(
            atPath: repo.url.appendingPathComponent("link.txt").path, withDestinationPath: "target.txt")
        let before = try #require(try await fingerprint("link.txt", area: .unstaged, in: repo))
        #expect(before.kind == .untracked)
        guard case .file = before.worktree else {
            Issue.record("expected the target's stat, got \(before.worktree)")
            return
        }

        try repo.write("target.txt", "one\ntwo\n")
        let after = try #require(try await fingerprint("link.txt", area: .unstaged, in: repo))
        #expect(DiffInputFingerprint.mayHaveChanged(before, after))
    }
}
