import Foundation

/// Thin wrapper over the `git` CLI for one repository.
struct GitClient: RepoClient {
    let repoRoot: URL
    /// Merged over `baseEnvironment` on every call, so tests can hand git a neutral identity
    /// and keep the developer's own config out.
    private let environmentOverrides: [String: String]
    /// Awaited only by the calls that run the user's hooks: `commit` and `switchBranch`.
    private let resolveHookEnvironment: @Sendable () async -> [String: String]

    init(
        repoRoot: URL,
        environment: [String: String] = [:],
        resolveHookEnvironment: @escaping @Sendable () async -> [String: String] = LoginShellPath.environment
    ) {
        self.repoRoot = repoRoot
        self.environmentOverrides = environment
        self.resolveHookEnvironment = resolveHookEnvironment
    }

    static let executable = URL(fileURLWithPath: "/usr/bin/git")

    /// Environment that avoids git taking the index lock or paging.
    private static let baseEnvironment = [
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_PAGER": "cat",
        "LC_ALL": "C",
    ]

    /// What every instance call passes to git: the static settings with this client's
    /// overrides on top.
    private var callEnvironment: [String: String] {
        Self.baseEnvironment.merging(environmentOverrides) { _, instance in instance }
    }

    /// What a call that runs hooks passes to git. Later wins: hooks need the login
    /// shell's PATH, and a caller's own overrides still beat both.
    private func hookEnvironment() async -> [String: String] {
        var environment = Self.baseEnvironment.merging(await resolveHookEnvironment()) { _, resolved in resolved }
        environment.merge(environmentOverrides) { _, instance in instance }
        return environment
    }

    /// Resolves the repository root containing `url`, or throws if it isn't inside a repo.
    static func discoverRoot(from url: URL) async throws -> URL {
        let result = try await ProcessRunner.check(
            executable,
            arguments: ["rev-parse", "--show-toplevel"],
            currentDirectory: url,
            environment: baseEnvironment
        )
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func status() async throws -> [ChangedFile] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--no-renames"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        // The parser cannot stat; the worktree half of an unstaged fingerprint is filled
        // in here, still off the main actor.
        return GitStatusParser.parse(result.stdout)
            .map { file in
                guard file.area == .unstaged, let fingerprint = file.fingerprint else { return file }
                let worktree = DiffInputFingerprint.worktree(at: repoRoot.appendingPathComponent(file.path))
                return file.with(fingerprint: fingerprint.with(worktree: worktree))
            }
            .sorted { ($0.area.sortOrder, $0.path) < ($1.area.sortOrder, $1.path) }
    }

    /// The commit HEAD resolves to, or nil when HEAD is unborn.
    func headSha() async throws -> String? {
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["rev-parse", "--verify", "--quiet", "HEAD"],
            currentDirectory: repoRoot,
            environment: callEnvironment
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
            environment: callEnvironment
        )
        guard symbolic.status == 0 else {
            throw ProcessError.failed(
                command: "git rev-parse --verify HEAD", status: result.status, stderr: result.stderrString)
        }
        return nil
    }

    /// Where HEAD points: a branch name, or the commit a detached HEAD sits on. An
    /// unborn branch still has a name.
    func headState() async throws -> HeadState {
        // The symbolic ref and the sha come from two separate processes, so the pair is
        // never one atomic view of HEAD. A checkout landing between the reads would
        // attach HEAD to a branch after its commit had already been read, and the answer
        // would claim a detached HEAD sitting on that branch's tip. So a HEAD that reads
        // as detached has its symbolic state read once more after the sha is known, and
        // that confirming read settles it either way: still detached and the sha stands,
        // attached and the branch it just named is the answer.
        for _ in 0..<3 {
            let result = try await readSymbolicHead()
            switch result.status {
            case 0:
                return .named(branchName(from: result))
            // `--quiet` promises exit 1 for a HEAD that is not a symbolic ref, which is
            // exactly a detached HEAD. Every other status is a real failure — a missing
            // repository, a damaged ref — and must not be reported as detached.
            case 1:
                // A switch to an unborn branch between the two reads leaves no commit to
                // report, which is what nil means here. There is nothing to confirm, so
                // read the whole state again.
                guard let sha = try await headSha() else { continue }
                let confirmation = try await readSymbolicHead()
                switch confirmation.status {
                case 1:
                    return .detached(sha: sha)
                // HEAD attached to a branch while the sha was being read, so that sha may
                // be the branch's tip rather than a detached HEAD's commit. The confirming
                // read already named the branch, so answer with that rather than re-reading.
                case 0:
                    return .named(branchName(from: confirmation))
                default:
                    throw ProcessError.failed(
                        command: "git symbolic-ref HEAD", status: confirmation.status,
                        stderr: confirmation.stderrString)
                }
            default:
                throw ProcessError.failed(
                    command: "git symbolic-ref HEAD", status: result.status, stderr: result.stderrString)
            }
        }
        // Three passes, and each one found HEAD detached and then unborn, with no commit
        // to report. A repository being rewritten this fast has no stable answer to give.
        throw ProcessError.failed(
            command: "git symbolic-ref HEAD", status: 1,
            stderr: "HEAD kept changing between reads")
    }

    /// The branch a successful `git symbolic-ref HEAD` names.
    private func branchName(from result: ProcessResult) -> String {
        Self.branchName(fromRef: result.stdoutString)
    }

    /// The branch name a full ref names: `refs/heads/main` → `main`. Only the line
    /// terminator is removed: git permits Unicode separators and trailing non-breaking
    /// spaces in a ref name, and trimming whitespace would corrupt those.
    private static func branchName(fromRef ref: String) -> String {
        let line = ref.hasSuffix("\n") ? String(ref.dropLast()) : ref
        let prefix = "refs/heads/"
        // A ref outside `refs/heads/` is not a branch, and there is nothing better to
        // call it than what git wrote.
        guard line.hasPrefix(prefix) else { return line }
        return String(line.dropFirst(prefix.count))
    }

    /// Local branch names sorted by ref name. An unborn branch has no ref and is omitted.
    func localBranches() async throws -> [String] {
        // `%(refname)`, not `%(refname:short)`: when a tag and a branch share a name, git
        // shortens `refs/heads/main` only as far as `heads/main` to stay unambiguous.
        // Stripping the prefix ourselves always yields the plain branch name.
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["for-each-ref", "--format=%(refname)", "refs/heads/"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        // The literal terminator, not `isNewline`, which would also split on a U+2028
        // inside a name.
        return result.stdoutString
            .split(separator: "\n")
            .map { Self.branchName(fromRef: String($0)) }
    }

    /// Reads HEAD's symbolic ref, leaving the exit status to the caller: `headState()`
    /// reads it twice and treats the statuses differently each time.
    private func readSymbolicHead() async throws -> ProcessResult {
        // Deliberately not `--short`: when a tag and a branch share a name, git shortens
        // `refs/heads/main` only as far as `heads/main` to stay unambiguous, and the
        // picker would show that verbatim. Reading the full ref and stripping the prefix
        // afterwards always yields the plain branch name.
        try await ProcessRunner.run(
            Self.executable,
            arguments: ["symbolic-ref", "--quiet", "HEAD"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
    }

    func recentCommits(startingAt revision: String, limit: Int) async throws -> [CommitSummary] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: [
                "log", "-z", "--first-parent", "-n", String(limit),
                "--format=%H%x00%h%x00%P%x00%an%x00%aI%x00%s", revision,
            ],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return try GitLogParser.parse(result.stdout)
    }

    func changedFiles(in commit: CommitRef) async throws -> [ChangedFile] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["diff-tree"] + Self.commitComparisonFlags(commit)
                + ["-r", "-z", "--name-status", "--no-renames"] + Self.commitOperands(commit),
            currentDirectory: repoRoot,
            environment: callEnvironment
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
            environment: callEnvironment
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
            environment: callEnvironment
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git show \(spec)", status: result.status, stderr: result.stderrString)
        }
        return result.stdout
    }

    /// Contents of `path` in the working tree, or nil if the path is not there.
    ///
    /// Only a missing file is nil. A file that exists but cannot be read — no permission,
    /// a directory in its place, a broken mount — throws, because the diff engine reads a
    /// nil as "this side does not exist" and would draw the file as deleted.
    func worktreeContents(of path: String) async throws -> Data? {
        do {
            return try Data(contentsOf: repoRoot.appendingPathComponent(path))
        } catch {
            guard Self.isMissingFile(error) else { throw error }
            return nil
        }
    }

    /// Whether an error from a file read means "not there". `Data(contentsOf:)` reports it
    /// as a Cocoa error; the POSIX spelling is kept for reads that come up from lower down.
    private static func isMissingFile(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError {
            return cocoa.code == .fileReadNoSuchFile || cocoa.code == .fileNoSuchFile
        }
        if let posix = error as? POSIXError { return posix.code == .ENOENT }
        return false
    }

    /// Runs `action` over every path in one git process. `check` turns a refusal into a
    /// `ProcessError.failed` that already carries git's stderr, which is the text the
    /// error alert shows.
    func perform(_ action: GitFileAction, on paths: [String]) async throws {
        // Never launch git for an empty list: `git reset -q --` with no pathspec resets
        // the whole index, and the other verbs fail with a usage error. The caller's
        // empty checks are not the boundary that matters; this is.
        guard !paths.isEmpty else { return }
        _ = try await ProcessRunner.check(
            Self.executable,
            arguments: action.arguments(for: paths),
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
    }

    /// Moves each worktree file to the Trash rather than unlinking it, so an accidental
    /// delete is recoverable from Finder. The first failure throws and the rest are left
    /// alone: the caller refreshes after a failed batch, so a half-done loop is visible.
    func trash(_ paths: [String]) async throws {
        for path in paths {
            try FileManager.default.trashItem(
                at: repoRoot.appendingPathComponent(path), resultingItemURL: nil)
        }
    }

    /// Merge/squash/template metadata the commit box prefills from, and whether a merge is
    /// in progress.
    func commitDefaults() async throws -> CommitDefaults {
        // One `rev-parse` for all three: only git knows where they live, which is not
        // `<root>/.git` in a linked worktree.
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: [
                "rev-parse", "--git-path", "MERGE_HEAD", "--git-path", "MERGE_MSG",
                "--git-path", "SQUASH_MSG",
            ],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        let files = result.stdoutString.split(whereSeparator: \.isNewline).map { gitPath(String($0)) }
        guard files.count == 3 else {
            throw ProcessError.failed(
                command: "git rev-parse --git-path", status: result.status,
                stderr: "expected three paths, got \(files.count)")
        }
        // MERGE_HEAD's existence is the merge, whatever the message files say.
        let isMerging = FileManager.default.fileExists(atPath: files[0].path)
        let merge = try Self.readText(at: files[1])
        let squash = try Self.readText(at: files[2])
        // The path is always resolved, so callers know the template is a dependency even
        // while merge metadata outranks it; the file is read only when it is the suggestion.
        let templatePath = try await templatePath()
        var template: String?
        if merge == nil, squash == nil, let templatePath {
            template = try Self.readText(at: templatePath)
        }
        return CommitDefaults(
            suggestion: CommitDefaults.resolveMessage(merge: merge, squash: squash, template: template),
            isMerging: isMerging,
            templateDependency: templatePath.map { .configured(path: $0.path) } ?? .none)
    }

    /// Records the index using a temporary message file and git's strip cleanup mode. The
    /// file keeps the message out of a refusal's diagnostics; `strip` matches what an edited
    /// message gets in the editor flow.
    func commit(message: String) async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffViewer-commit-\(UUID().uuidString)")
        try message.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["commit", "--cleanup=strip", "-F", file.path],
            currentDirectory: repoRoot,
            environment: await hookEnvironment()
        )
        // Not `check`: its label would echo the temp file's path into the alert.
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git commit", status: result.status, stderr: Self.hookDiagnostics(result))
        }
    }

    /// Switches to an existing local branch. Runs the user's post-checkout hook, so it
    /// takes the hook environment.
    func switchBranch(to branch: String) async throws {
        // Git itself would read a leading dash as an option.
        guard !branch.hasPrefix("-") else {
            throw ProcessError.failed(
                command: "git switch", status: 128, stderr: "'\(branch)' is not a branch name")
        }
        // `--no-guess`: a stale menu entry whose local branch was deleted must not create
        // a tracking branch from a matching remote.
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["switch", "--no-guess", branch],
            currentDirectory: repoRoot,
            environment: await hookEnvironment()
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git switch", status: result.status, stderr: Self.hookDiagnostics(result))
        }
    }

    /// Both streams of a failed hook-running command, because hooks often explain
    /// themselves on stdout while git warns on stderr.
    private static func hookDiagnostics(_ result: ProcessResult) -> String {
        [result.stderrString, result.stdoutString]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Where `commit.template` points, or nil when it is not set.
    private func templatePath() async throws -> URL? {
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["config", "-z", "--path", "--get", "commit.template"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        // Status 1 is "no such key"; any other non-zero is a real config failure.
        if result.status == 1 { return nil }
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git config commit.template", status: result.status, stderr: result.stderrString)
        }
        // `-z` and a single NUL stripped, not trimming: whitespace in a filename is meaningful.
        var path = result.stdoutString
        if path.hasSuffix("\0") { path.removeLast() }
        guard !path.isEmpty else { return nil }
        return gitPath(path)
    }

    /// Resolves a git-reported path against the repository root; a linked worktree's are
    /// already absolute.
    private func gitPath(_ path: String) -> URL {
        URL(fileURLWithPath: path, relativeTo: repoRoot).absoluteURL
    }

    /// Text of a git metadata file, or nil when it is not there. Every other read failure
    /// throws rather than becoming an empty message.
    private static func readText(at url: URL) throws -> String? {
        do {
            let data = try Data(contentsOf: url)
            return String(decoding: data, as: UTF8.self)
        } catch {
            guard isMissingFile(error) else { throw error }
            return nil
        }
    }

    private func show(_ spec: String) async throws -> Data? {
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["show", spec],
            currentDirectory: repoRoot,
            environment: callEnvironment
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
