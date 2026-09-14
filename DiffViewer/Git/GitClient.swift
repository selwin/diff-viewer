import Foundation

/// Thin wrapper over the `git` CLI for one repository.
struct GitClient: RepoClient {
    let repoRoot: URL

    static let executable = URL(fileURLWithPath: "/usr/bin/git")

    /// Environment that avoids git taking the index lock or paging.
    private static let environment = [
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_PAGER": "cat",
        "LC_ALL": "C",
    ]

    /// Resolves the repository root containing `url`, or throws if it isn't inside a repo.
    static func discoverRoot(from url: URL) async throws -> URL {
        let result = try await ProcessRunner.check(
            executable,
            arguments: ["rev-parse", "--show-toplevel"],
            currentDirectory: url,
            environment: environment
        )
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func status() async throws -> [ChangedFile] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--no-renames"],
            currentDirectory: repoRoot,
            environment: Self.environment
        )
        return GitStatusParser.parse(result.stdout)
            .sorted { ($0.area.sortOrder, $0.path) < ($1.area.sortOrder, $1.path) }
    }

    /// The commit HEAD resolves to, or nil when HEAD is unborn.
    func headSha() async throws -> String? {
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["rev-parse", "--verify", "--quiet", "HEAD"],
            currentDirectory: repoRoot,
            environment: Self.environment
        )
        if result.status == 0 {
            return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // `--quiet` suppressed the diagnostic, so empty output proves nothing on its own;
        // this second process runs only on the failure path, so the common case stays a
        // single call.
        //
        // HEAD is unborn only when it is a symbolic ref to a branch with no commits yet.
        // A damaged ref does not slip through as "no commits": `symbolic-ref` itself
        // exits 128 when HEAD's target is malformed, so it reaches the throw below.
        // (`show-ref --verify` cannot sharpen this — it exits non-zero for an absent ref
        // and a corrupt one alike, so it would separate nothing.)
        let symbolic = try await ProcessRunner.run(
            Self.executable,
            arguments: ["symbolic-ref", "--quiet", "HEAD"],
            currentDirectory: repoRoot,
            environment: Self.environment
        )
        guard symbolic.status == 0 else {
            throw ProcessError.failed(
                command: "git rev-parse --verify HEAD", status: result.status, stderr: result.stderrString)
        }
        return nil
    }

    func recentCommits(startingAt revision: String, limit: Int) async throws -> [CommitSummary] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: [
                "log", "-z", "--first-parent", "-n", String(limit),
                "--format=%H%x00%h%x00%P%x00%an%x00%aI%x00%s", revision,
            ],
            currentDirectory: repoRoot,
            environment: Self.environment
        )
        return try GitLogParser.parse(result.stdout)
    }

    func changedFiles(in commit: CommitRef) async throws -> [ChangedFile] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["diff-tree"] + Self.commitComparisonFlags(commit)
                + ["-r", "-z", "--name-status", "--no-renames"] + Self.commitOperands(commit),
            currentDirectory: repoRoot,
            environment: Self.environment
        )
        return GitNameStatusParser.parse(result.stdout, area: .commit(commit))
    }

    /// Per-file added/deleted line counts for `area`: HEAD → index for `.staged`,
    /// index → worktree for `.unstaged`, first parent → commit for `.commit`. Untracked
    /// files never appear.
    func numstat(area: ChangedFile.Area, ignoreWhitespace: Bool) async throws -> [NumstatEntry] {
        // Flags first, operands last: a commit's operands end in `--`, after which git
        // reads every argument as a pathspec, so a trailing `-w` would be silently taken
        // as a file name and the command would report no changes at all.
        var flags: [String]
        var operands: [String] = []
        switch area {
        case .unstaged:
            flags = ["diff", "--numstat", "-z", "--no-renames"]
        case .staged:
            flags = ["diff", "--cached", "--numstat", "-z", "--no-renames"]
        case let .commit(ref):
            flags = ["diff-tree"] + Self.commitComparisonFlags(ref) + ["-r", "--numstat", "-z", "--no-renames"]
            operands = Self.commitOperands(ref)
        }
        if ignoreWhitespace { flags.append("-w") }
        let arguments = flags + operands
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: arguments,
            currentDirectory: repoRoot,
            environment: Self.environment
        )
        return GitNumstatParser.parse(result.stdout)
    }

    /// Flags that select what a commit is compared against. A root commit needs `--root`
    /// to be diffed against the empty tree, and `--no-commit-id` to suppress the header
    /// line that form prints.
    private static func commitComparisonFlags(_ commit: CommitRef) -> [String] {
        commit.firstParentSHA == nil ? ["--no-commit-id", "--root"] : []
    }

    /// The revisions to compare. Naming both trees explicitly is required, not
    /// stylistic: given only a commit, `diff-tree` prints nothing at all for a merge
    /// unless `-m`/`-c`/`--cc` is passed, which would show every merge as an empty
    /// changeset. The pair also states the first-parent promise literally.
    private static func commitOperands(_ commit: CommitRef) -> [String] {
        guard let parent = commit.firstParentSHA else { return [commit.sha] }
        return [parent, commit.sha, "--"]
    }

    /// Contents of `path` in the index, or nil if the path is not in the index.
    func indexContents(of path: String) async throws -> Data? {
        try await show(":\(path)")
    }

    /// Contents of `path` at HEAD, or nil if the path does not exist there.
    func headContents(of path: String) async throws -> Data? {
        try await show("HEAD:\(path)")
    }

    /// Contents of `path` at `revision`, throwing if git cannot produce them.
    ///
    /// Deliberately not routed through `show(_:)`: that treats a failure as "absent",
    /// which is right for the index and for HEAD in a repository with no commits, but
    /// wrong here. Git reports an unreadable revision as though the path were missing —
    /// `git show <unknown-sha>:README.md` says "path 'README.md' exists on disk, but not
    /// in '<sha>'" — so being lenient would render an unreachable commit as a file added
    /// wholesale. Callers read only the sides the change kind says exist, so anything
    /// missing here is a real error.
    func contents(of path: String, at revision: String) async throws -> Data {
        let spec = "\(revision):\(path)"
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["show", spec],
            currentDirectory: repoRoot,
            environment: Self.environment
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git show \(spec)", status: result.status, stderr: result.stderrString)
        }
        return result.stdout
    }

    /// Contents of `path` in the working tree, or nil if missing.
    func worktreeContents(of path: String) async -> Data? {
        try? Data(contentsOf: repoRoot.appendingPathComponent(path))
    }

    /// Runs `action` on one path. `check` turns a refusal into a `ProcessError.failed`
    /// that already carries git's stderr, which is the text the error alert shows.
    func perform(_ action: GitFileAction, on path: String) async throws {
        _ = try await ProcessRunner.check(
            Self.executable,
            arguments: action.arguments(for: path),
            currentDirectory: repoRoot,
            environment: Self.environment
        )
    }

    /// Moves the worktree file to the Trash rather than unlinking it, so an accidental
    /// delete is recoverable from Finder.
    func trash(_ path: String) async throws {
        try FileManager.default.trashItem(
            at: repoRoot.appendingPathComponent(path), resultingItemURL: nil)
    }

    private func show(_ spec: String) async throws -> Data? {
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["show", spec],
            currentDirectory: repoRoot,
            environment: Self.environment
        )
        if result.status == 0 { return result.stdout }
        let stderr = result.stderrString
        if stderr.contains("does not exist") || stderr.contains("exists on disk, but not in")
            || stderr.contains("is in the index, but not at stage") || stderr.contains("Invalid object name")
        {
            return nil
        }
        throw ProcessError.failed(command: "git show \(spec)", status: result.status, stderr: stderr)
    }
}
