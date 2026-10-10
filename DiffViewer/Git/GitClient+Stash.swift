import Foundation

extension GitClient {
    /// The stash list, newest first. `stash list` is `log -g --first-parent -m`, so
    /// `--shortstat` counts each stash's tracked changes against its first parent; one more
    /// read adds the untracked files' counts.
    func stashes() async throws -> [StashEntry] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: [
                "stash", "list", "--format=%x00%H%x00%h%x00%P%x00%cI%x00%an%x00%gs%x00", "--shortstat",
            ],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        let entries = try StashListParser.parse(result.stdout)
        let untrackedParents = entries.compactMap(\.untrackedParentSHA)
        guard !untrackedParents.isEmpty else { return entries }
        let counts = try? await untrackedChurn(of: untrackedParents)
        return entries.map { $0.addingUntrackedChurn(counts) }
    }

    /// Counts the lines in each third parent. They are root commits, so `--root` diffs
    /// them against the empty tree even when `log.showRoot` is off.
    private func untrackedChurn(of parents: [String]) async throws -> [String: StashEntry.Churn] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["log", "--no-walk", "--root", "--format=%x00%H", "--shortstat"] + parents + ["--"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return try StashListParser.parseUntrackedChurn(result.stdout)
    }

    /// Lists first-parent changes and any files saved in a stash's third parent.
    func changedFiles(in commit: CommitRef) async throws -> [ChangedFile] {
        guard let untracked = commit.untrackedCommit else { return try await firstParentChanges(in: commit) }
        async let tracked = firstParentChanges(in: commit)
        async let added = firstParentChanges(in: untracked)
        return try await tracked + added
    }
}
