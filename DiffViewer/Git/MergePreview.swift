/// Predicted merge result for two commits; leaves the index and working tree unchanged.
enum MergePreview: Sendable, Equatable {
    /// The destination commit already contains the source.
    case alreadyMerged
    /// The source's `commits` merge without conflicts.
    case clean(commits: Int)
    /// The merge would stop on conflicts in `paths`. Empty when git reported a conflict
    /// without naming a file, which is still a conflict.
    case conflicts(commits: Int, paths: [String])
}

extension MergePreview {
    /// How many commits the merge brings in; zero when already merged.
    var commitCount: Int {
        switch self {
        case .alreadyMerged: 0
        case let .clean(commits): commits
        case let .conflicts(commits, _): commits
        }
    }
}

/// Parses `git merge-tree --write-tree --name-only --no-messages -z`: the merged tree's
/// object id, then each conflicted path, every one terminated by NUL.
enum MergeTreeParser {
    /// The conflicted paths in git's order. Never split on newlines: a path may hold
    /// spaces, tabs and newlines, and `-z` is what keeps them unquoted.
    static func conflictedPaths(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(separator: "\0", omittingEmptySubsequences: true).dropFirst()
            .map(String.init)
            .filter { seen.insert($0).inserted }
    }
}
