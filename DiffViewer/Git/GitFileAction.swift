import Foundation

/// A whole-file git write the sidebar can ask for.
///
/// Every case moves one path between the worktree, the index, and HEAD; none of them
/// edits file contents and none commits. `.stage` is also how a deletion is recorded
/// and how a conflicted path is marked resolved — `git add` covers all three — and
/// `.discard` is also how a deleted file is brought back, since `git restore` rewrites
/// the worktree from the index either way.
enum GitFileAction: Equatable, Sendable {
    case stage
    case unstage
    case discard

    /// The full argument list for `git`, path last.
    ///
    /// `--literal-pathspecs` because git reads a pathspec as a glob by default, so a real
    /// file named `a[1].txt` would match nothing and the command would silently do
    /// something other than what the row said. `--` keeps a path that looks like an
    /// option from being parsed as one.
    ///
    /// `.unstage` is `reset` rather than `restore --staged` because `restore --staged`
    /// needs HEAD to exist: in a repository with no commits it fails with
    /// "fatal: could not resolve 'HEAD'", and there every staged file is a staged add.
    /// `reset -q -- <path>` resets the index entry from HEAD exactly like
    /// `restore --staged` when HEAD exists, and drops the entry when it does not, leaving
    /// the file untracked in the worktree with its contents intact.
    func arguments(for path: String) -> [String] {
        switch self {
        case .stage: ["--literal-pathspecs", "add", "--", path]
        case .unstage: ["--literal-pathspecs", "reset", "-q", "--", path]
        case .discard: ["--literal-pathspecs", "restore", "--", path]
        }
    }
}
