import Foundation

/// A whole-file git write the sidebar can ask for.
///
/// Every case moves paths between the worktree, the index, and HEAD; none of them edits
/// file contents, and commits are made by `RepoClient.commit(message:)`. `.stage` is also
/// how a deletion is recorded and how a conflicted path is marked resolved — `git add`
/// covers all three — and
/// `.discard` is also how a deleted file is brought back, since `git restore` rewrites
/// the worktree from the index either way.
enum GitFileAction: Equatable, Sendable {
    case stage
    case unstage
    case discard

    /// The full argument list for `git`, paths last.
    ///
    /// Treat paths literally (a real `a[1].txt` must not be read as a glob) and place them
    /// after `--` so none is parsed as an option.
    ///
    /// `.unstage` is `reset` rather than `restore --staged` because `restore --staged`
    /// needs HEAD to exist: in a repository with no commits it fails with
    /// "fatal: could not resolve 'HEAD'", and there every staged file is a staged add.
    /// `reset -q -- <paths>` resets the index entries from HEAD exactly like
    /// `restore --staged` when HEAD exists, and drops the entries when it does not, leaving
    /// the files untracked in the worktree with their contents intact.
    func arguments(for paths: [String]) -> [String] {
        switch self {
        case .stage: ["--literal-pathspecs", "add", "--"] + paths
        case .unstage: ["--literal-pathspecs", "reset", "-q", "--"] + paths
        case .discard: ["--literal-pathspecs", "restore", "--"] + paths
        }
    }
}
