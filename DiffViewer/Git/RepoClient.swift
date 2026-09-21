import Foundation

/// Where HEAD points: a branch name, or the commit a detached HEAD sits on. An enum
/// rather than `String?` so "not read yet" stays distinct from "detached": an unread
/// state must not render as a detached HEAD.
enum HeadState: Sendable, Equatable {
    case named(String)
    case detached(sha: String)
}

/// The repository operations the app needs. `GitClient` is the real one; tests use
/// actor-backed stubs, which is why every method is async.
protocol RepoClient: Sendable {
    func status() async throws -> [ChangedFile]
    /// The commit HEAD resolves to, or nil when HEAD is unborn (a branch with no commits
    /// yet). Every other failure throws, so a broken repository is never reported as an
    /// empty history.
    func headSha() async throws -> String?
    /// Where HEAD points: a branch name, or the commit a detached HEAD sits on. An
    /// unborn branch still has a name.
    func headState() async throws -> HeadState
    /// Local branches sorted by ref name. An unborn branch has no ref and is omitted.
    func localBranches() async throws -> [LocalBranch]
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
    /// The stored size of each object, one entry per spec in order: a blob id or a
    /// `<rev>:<path>`. Nil where git has no such object. An empty list never launches git.
    func objectSizes(of specs: [String]) async throws -> [Int64?]
    /// Contents of `path` in the index, or nil if the path is not in the index.
    func indexContents(of path: String) async throws -> Data?
    /// Contents of `path` at HEAD, or nil if the path does not exist there.
    func headContents(of path: String) async throws -> Data?
    /// Contents of `path` at `revision`. Throws rather than reporting a missing revision
    /// as absent content: git describes an unreadable revision as though the *path* were
    /// missing, so a nil here would render an unreachable commit as a file that was added
    /// wholesale. Callers read only the sides the change kind says exist.
    func contents(of path: String, at revision: String) async throws -> Data
    /// Contents of `path` in the working tree, or nil if the path is not there. Every
    /// other read failure throws: reporting an unreadable file as absent would draw a
    /// modified file as deleted.
    func worktreeContents(of path: String) async throws -> Data?
    /// Runs `action` over every path in one git process, throwing git's stderr if it
    /// refuses. An empty list does nothing. All whole-file: nothing here edits contents.
    func perform(_ action: GitFileAction, on paths: [String]) async throws
    /// Moves each worktree file to the Trash, so deleting an untracked file is
    /// recoverable from Finder. An empty list does nothing. Git cannot do this — an
    /// untracked path is not in the index — which makes it the app's only write outside
    /// git, and it lives here so tests can stub it rather than touching the real Trash.
    func trash(_ paths: [String]) async throws
    /// Merge/squash/template metadata the commit box prefills from, and whether a merge is
    /// in progress. Throws when the repository's own state cannot be read.
    func commitDefaults() async throws -> CommitDefaults
    /// The staged changes as `git diff --cached --patch-with-stat` prints them: a stat,
    /// then the patch.
    func stagedPatch() async throws -> String
    /// Records the index as a commit with `message`: `git commit --cleanup=strip -F <file>`.
    /// Throws git's and the hooks' diagnostics when it refuses (nothing staged, a failing
    /// hook, no identity).
    func commit(message: String) async throws
    /// Switches to an existing local branch without creating a tracking branch. Throws
    /// git's and the hooks' diagnostics when it refuses or a post-checkout hook fails.
    func switchBranch(to branch: String) async throws
    /// The names of the configured remotes, in git's order.
    func remoteNames() async throws -> [String]
    /// Updates the remote-tracking refs of `remote`, never pruning. Throws git's diagnostics.
    func fetch(remote: String) async throws
    /// Brings the current branch up to date with its upstream, merging or rebasing as config says.
    func pull() async throws
    /// Sends `branch` to `remoteRef` on `remote`, fast-forward only.
    func push(branch: String, to remote: String, remoteRef: String) async throws
}
