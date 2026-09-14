import Foundation

/// The repository operations the app needs. `GitClient` is the real one; tests use
/// actor-backed stubs, which is why every method is async.
protocol RepoClient: Sendable {
    func status() async throws -> [ChangedFile]
    /// The commit HEAD resolves to, or nil when HEAD is unborn (a branch with no commits
    /// yet). Every other failure throws, so a broken repository is never reported as an
    /// empty history.
    func headSha() async throws -> String?
    /// The branch's commits, newest first, following first parents only.
    ///
    /// Takes the revision to start from rather than reading HEAD itself: the caller
    /// resolves HEAD once, so a checkout between the two reads cannot pair one
    /// revision's history with another's.
    func recentCommits(startingAt revision: String, limit: Int) async throws -> [CommitSummary]
    /// The files `commit` changed against its first parent, or against the empty tree at
    /// a root commit.
    func changedFiles(in commit: CommitRef) async throws -> [ChangedFile]
    /// Per-file added/deleted line counts for `area`: HEAD → index for `.staged`,
    /// index → worktree for `.unstaged`, first parent → commit for `.commit`. Untracked
    /// files never appear.
    func numstat(area: ChangedFile.Area, ignoreWhitespace: Bool) async throws -> [NumstatEntry]
    /// Contents of `path` in the index, or nil if the path is not in the index.
    func indexContents(of path: String) async throws -> Data?
    /// Contents of `path` at HEAD, or nil if the path does not exist there.
    func headContents(of path: String) async throws -> Data?
    /// Contents of `path` at `revision`. Throws rather than reporting a missing revision
    /// as absent content: git describes an unreadable revision as though the *path* were
    /// missing, so a nil here would render an unreachable commit as a file that was added
    /// wholesale. Callers read only the sides the change kind says exist.
    func contents(of path: String, at revision: String) async throws -> Data
    /// Contents of `path` in the working tree, or nil if missing.
    func worktreeContents(of path: String) async -> Data?
    /// Runs `action` on one path, throwing git's stderr if it refuses. The only
    /// repository writes the app makes, and all whole-file: nothing here edits contents
    /// or creates a commit.
    func perform(_ action: GitFileAction, on path: String) async throws
    /// Moves the worktree file at `path` to the Trash, so deleting an untracked file is
    /// recoverable from Finder. Git cannot do this — an untracked path is not in the
    /// index — which makes it the app's only write outside git, and it lives here so
    /// tests can stub it rather than touching the real Trash.
    func trash(_ path: String) async throws
}
