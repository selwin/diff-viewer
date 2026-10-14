import Foundation

/// Diffs between two fixed revisions: a commit against its first parent, or a range against its merge base. Split from `GitClient.swift` to keep it under the length lint.
extension GitClient {
    /// The files that differ between `pair`'s trees, or between the empty tree and the
    /// target when there is no base, listed under `area`.
    func treeChanges(_ pair: RevisionPair, area: ChangedFile.Area) async throws -> [ChangedFile] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["diff-tree"] + Self.revisionComparisonFlags(pair)
                + ["-r", "-z", "--name-status", "--find-renames=100%"] + Self.revisionOperands(pair),
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return GitNameStatusParser.parse(result.stdout, area: area)
    }

    /// Per-file added/deleted line counts for `area`: HEAD → index for `.staged`,
    /// index → worktree for `.unstaged`, first parent → commit for `.commit`, merge base
    /// → target for `.range`. Untracked files never appear.
    func numstat(area: ChangedFile.Area, ignoreWhitespace: Bool) async throws -> [NumstatEntry] {
        // Flags first, operands last: a revision pair's operands end in `--`, after which git
        // reads every argument as a pathspec, so a trailing `-w` would be silently taken
        // as a file name and the command would report no changes at all.
        // Rename detection matches `status()` and `changedFiles(in:)`, so a rename's
        // counts are keyed by its new path, the path its row carries.
        var flags: [String]
        var operands: [String] = []
        switch area {
        case .unstaged:
            flags = ["diff", "--numstat", "-z", "--find-renames=100%"]
        case .staged:
            flags = ["diff", "--cached", "--numstat", "-z", "--find-renames=100%"]
        case .commit, .range:
            guard let pair = area.revisionPair else { return [] }
            flags =
                ["diff-tree"] + Self.revisionComparisonFlags(pair) + ["-r", "--numstat", "-z", "--find-renames=100%"]
            operands = Self.revisionOperands(pair)
        }
        if ignoreWhitespace { flags.append("-w") }
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: flags + operands,
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return GitNumstatParser.parse(result.stdout)
    }

    /// Flags that select what the target is compared against. A root commit needs `--root`
    /// to be diffed against the empty tree, and `--no-commit-id` to suppress the header
    /// line that form prints.
    private static func revisionComparisonFlags(_ pair: RevisionPair) -> [String] {
        pair.baseSHA == nil ? ["--no-commit-id", "--root"] : []
    }

    /// The revisions to compare. Naming both trees explicitly is required, not
    /// stylistic: given only a commit, `diff-tree` prints nothing at all for a merge
    /// unless `-m`/`-c`/`--cc` is passed, which would show every merge as an empty
    /// changeset.
    private static func revisionOperands(_ pair: RevisionPair) -> [String] {
        guard let base = pair.baseSHA else { return [pair.targetSHA] }
        return [base, pair.targetSHA, "--"]
    }
}
