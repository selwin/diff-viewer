import Foundation
import Testing

@testable import DiffViewer

/// Commit paths run against the real `git`, because what a commit records and what git
/// leaves behind for the next one are things no stub can be trusted to imitate: MERGE_MSG
/// is written by git, `--cleanup=strip` follows `core.commentChar`, and a template path is
/// resolved against the repository rather than the process's working directory.
@Suite(.serialized) struct GitCommitCommandTests {
    // MARK: Building repositories

    /// Runs a git command that is expected to fail, since `Repo.git` throws on a non-zero
    /// exit and a conflicting merge exits non-zero by design.
    private func gitExpectingFailure(_ arguments: [String], in repo: GitCommandTests.Repo) async throws {
        let result = try await ProcessRunner.run(
            GitClient.executable,
            arguments: arguments,
            currentDirectory: repo.url,
            environment: GitCommandTests.Repo.environment
        )
        #expect(result.status != 0, "`git \(arguments.joined(separator: " "))` was expected to fail")
    }

    /// A repository stopped mid-merge with its one conflict resolved and staged: MERGE_HEAD
    /// and MERGE_MSG both exist, and the message carries git's commented Conflicts block.
    private func conflictedMerge(commentChar: String? = nil) async throws -> GitCommandTests.Repo {
        let repo = try GitCommandTests.Repo()
        try await repo.initialize()
        try await repo.prepareForCommits()
        try repo.write("file.txt", "base\n")
        try repo.write("other.txt", "untouched\n")
        try await repo.commit("Root commit")

        // Git writes the Conflicts block with the comment character in force at the time
        // of the merge, so this has to be configured before it runs.
        if let commentChar {
            try await repo.git(["config", "core.commentChar", commentChar])
        }

        try await repo.git(["checkout", "-b", "side"])
        try repo.write("file.txt", "side\n")
        try await repo.commit("Side commit")

        try await repo.git(["checkout", "main"])
        try repo.write("file.txt", "main\n")
        try await repo.commit("Main commit")

        try await gitExpectingFailure(["merge", "side"], in: repo)
        try repo.write("file.txt", "resolved\n")
        try await repo.git(["add", "file.txt"])
        return repo
    }

    // MARK: Committing

    @Test func commitRecordsTheIndexAndLeavesUnstagedWorkAlone() async throws {
        let repo = try GitCommandTests.Repo()
        try await repo.initialize()
        try await repo.prepareForCommits()
        try repo.write("a.txt", "one\n")
        try repo.write("b.txt", "one\n")
        try await repo.commit("Root commit")
        let before = try await repo.git(["rev-parse", "HEAD"])

        try repo.write("a.txt", "two\n")
        try await repo.git(["add", "a.txt"])
        try repo.write("b.txt", "two\n")

        try await repo.client.commit(message: "Change a")

        #expect(try await repo.git(["log", "-1", "--format=%B"]) == "Change a")
        #expect(try await repo.git(["rev-parse", "HEAD"]) != before)
        let files = try await repo.client.status()
        #expect(files.map(\.path) == ["b.txt"], "the staged file is committed, the edit to the other one is not")
        #expect(files.first?.area == .unstaged)
    }

    /// Git refuses an empty commit outside a merge, and the refusal has to reach the caller
    /// rather than passing for a commit that was made.
    @Test func committingWithNothingStagedThrows() async throws {
        let repo = try GitCommandTests.Repo()
        try await repo.initialize()
        try await repo.prepareForCommits()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")

        await #expect(throws: (any Error).self) {
            try await repo.client.commit(message: "Nothing")
        }
    }

    // MARK: Merges

    @Test func aConflictedMergeSuggestsGitsOwnMergeMessage() async throws {
        let repo = try await conflictedMerge()
        let defaults = try await repo.client.commitDefaults()

        #expect(defaults.isMerging)
        let suggestion = try #require(defaults.suggestion)
        #expect(suggestion.source == .merge)
        #expect(suggestion.text.hasPrefix("Merge branch 'side'"), "\(suggestion.text)")
        #expect(suggestion.text.contains("Conflicts:"), "\(suggestion.text)")
    }

    @Test func committingTheMergeSuggestionRecordsBothParents() async throws {
        let repo = try await conflictedMerge()
        let defaults = try await repo.client.commitDefaults()
        let suggestion = try #require(defaults.suggestion)

        try await repo.client.commit(message: suggestion.text)

        let parents = try await repo.git(["rev-list", "--parents", "-1", "HEAD"]).split(separator: " ")
        #expect(parents.count == 3, "the merge commit and its two parents")
        let message = try await repo.git(["log", "-1", "--format=%B"])
        #expect(message.hasPrefix("Merge branch 'side'"), "\(message)")
        #expect(!message.contains("Conflicts:"), "the commented block is stripped: \(message)")
        #expect(try await repo.client.commitDefaults() == CommitDefaults.none, "the merge is over")
    }

    /// `--cleanup=strip` strips whatever `core.commentChar` says, so a repository that does
    /// not use `#` must still lose the commented block rather than commit it as prose.
    @Test func aCustomCommentCharIsStrippedToo() async throws {
        let repo = try await conflictedMerge(commentChar: ";")
        let defaults = try await repo.client.commitDefaults()
        let suggestion = try #require(defaults.suggestion)
        #expect(suggestion.text.contains("Conflicts:"), "\(suggestion.text)")

        try await repo.client.commit(message: suggestion.text)

        let message = try await repo.git(["log", "-1", "--format=%B"])
        #expect(message.hasPrefix("Merge branch 'side'"), "\(message)")
        #expect(!message.contains("Conflicts:"), "\(message)")
    }

    /// With `core.commentChar=auto` git picks the character from the message itself, so what
    /// survives cleanup is git's business: the claim here is parity with `git commit`, not
    /// that any particular line disappears.
    @Test func commitMatchesGitsOwnMessageUnderAutomaticCommentChar() async throws {
        let mine = try await conflictedMerge(commentChar: "auto")
        let theirs = try await conflictedMerge(commentChar: "auto")

        let defaults = try await mine.client.commitDefaults()
        let suggestion = try #require(defaults.suggestion)
        try await mine.client.commit(message: suggestion.text)
        try await theirs.git(["commit"], extraEnvironment: ["GIT_EDITOR": "true"])

        let mineMessage = try await mine.git(["log", "-1", "--format=%B"])
        let theirsMessage = try await theirs.git(["log", "-1", "--format=%B"])
        #expect(mineMessage == theirsMessage, "\(mineMessage) != \(theirsMessage)")
    }

    @Test func aSquashMergeSuggestsTheSquashMessage() async throws {
        let repo = try GitCommandTests.Repo()
        try await repo.initialize()
        try await repo.prepareForCommits()
        try repo.write("file.txt", "base\n")
        try await repo.commit("Root commit")
        try await repo.git(["checkout", "-b", "side"])
        try repo.write("side.txt", "from the side\n")
        try await repo.commit("Side commit")
        try await repo.git(["checkout", "main"])
        try await repo.git(["merge", "--squash", "side"])

        let defaults = try await repo.client.commitDefaults()
        #expect(!defaults.isMerging, "a squash merge writes no MERGE_HEAD")
        let suggestion = try #require(defaults.suggestion)
        #expect(suggestion.source == .squash)
        #expect(suggestion.text.hasPrefix("Squashed commit"), "\(suggestion.text)")
    }

    // MARK: Templates

    @Test func anAbsoluteCommitTemplateIsTheSuggestion() async throws {
        let repo = try GitCommandTests.Repo()
        try await repo.initialize()
        try await repo.prepareForCommits()
        try repo.write("tmpl.txt", "Subject line\n\n")
        try await repo.git(["config", "commit.template", repo.url.appendingPathComponent("tmpl.txt").path])

        let defaults = try await repo.client.commitDefaults()
        #expect(!defaults.isMerging)
        let suggestion = try #require(defaults.suggestion)
        #expect(suggestion.source == .template)
        #expect(suggestion.text == "Subject line\n\n")
    }

    /// Git ignores the template once a merge is in progress, and so must the prefill: a
    /// merge message is what the commit is actually about.
    @Test func mergeMetadataWinsOverTheCommitTemplate() async throws {
        let repo = try await conflictedMerge()
        // A directory cannot be read as text, and the failure is not "no such file", so
        // reaching a merge suggestion at all proves the template was never opened.
        try await repo.git(["config", "commit.template", repo.url.path])

        let defaults = try await repo.client.commitDefaults()
        let suggestion = try #require(defaults.suggestion)
        #expect(suggestion.source == .merge)
    }

    /// A relative template is relative to the repository, never to the process's working
    /// directory, which here is not the repository under test.
    @Test func aRelativeCommitTemplateResolvesAgainstTheRoot() async throws {
        let repo = try GitCommandTests.Repo()
        try await repo.initialize()
        try await repo.prepareForCommits()
        try repo.write("tmpl.txt", "Subject line\n\n")
        try await repo.git(["config", "commit.template", "tmpl.txt"])

        let defaults = try await repo.client.commitDefaults()
        let suggestion = try #require(defaults.suggestion)
        #expect(suggestion.source == .template)
        #expect(suggestion.text == "Subject line\n\n")
    }

    /// A template path is git's value verbatim, so a name that begins with a space is still
    /// the file it names.
    @Test func aTemplatePathKeepsItsWhitespace() async throws {
        let repo = try GitCommandTests.Repo()
        try await repo.initialize()
        try await repo.prepareForCommits()
        try repo.write(" tmpl.txt", "Subject line\n\n")
        try await repo.git(["config", "commit.template", " tmpl.txt"])

        let defaults = try await repo.client.commitDefaults()
        let suggestion = try #require(defaults.suggestion)
        #expect(suggestion.source == .template)
        #expect(suggestion.text == "Subject line\n\n")
    }

    @Test func aCleanRepositorySuggestsNothing() async throws {
        let repo = try GitCommandTests.Repo()
        try await repo.initialize()
        try await repo.prepareForCommits()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")

        #expect(try await repo.client.commitDefaults() == CommitDefaults.none)
    }

    // MARK: Hooks

    /// The whole point of resolving an environment for commits: a hook sees the login
    /// shell's PATH, and a caller's own overrides still beat it.
    @Test func aHookSeesTheResolvedPathAndTheClientsOverrides() async throws {
        let repo = try GitCommandTests.Repo()
        try await repo.initialize()
        try await repo.prepareForCommits()
        try repo.write("a.txt", "one\n")
        try await repo.commit("Root commit")
        try repo.write("a.txt", "two\n")
        try await repo.git(["add", "a.txt"])

        let hooks = repo.url.appendingPathComponent(".git/test-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        let script = """
            #!/bin/sh
            printf '%s\\n%s\\n' "$PATH" "$DIFFVIEWER_PROBE" > "$DIFFVIEWER_PROBE_FILE"

            """
        try Data(script.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try await repo.git(["config", "core.hooksPath", hooks.path])

        let probe = repo.url.appendingPathComponent(".git/probe.txt")
        let resolvedPath = "/diffviewer-test/bin:/usr/bin:/bin"
        let client = GitClient(
            repoRoot: repo.url,
            environment: GitCommandTests.Repo.environment.merging(
                ["DIFFVIEWER_PROBE": "override", "DIFFVIEWER_PROBE_FILE": probe.path]
            ) { $1 },
            resolveCommitEnvironment: { ["PATH": resolvedPath, "DIFFVIEWER_PROBE": "resolved"] }
        )

        try await client.commit(message: "Change a")

        let lines = try String(contentsOf: probe, encoding: .utf8).split(separator: "\n").map(String.init)
        // Git puts its own exec path in front of PATH for hooks, so the tail is what was handed in.
        #expect(lines.count == 2, "\(lines)")
        #expect(lines.first?.hasSuffix(":" + resolvedPath) == true, "\(lines)")
        #expect(lines.last == "override", "\(lines)")
    }
}
