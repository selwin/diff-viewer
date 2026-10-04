import Foundation

/// Merging another branch into the current one. Split from `GitClient.swift` to keep it
/// under the length lint.
extension GitClient {
    /// What merging `sourceTipSha` into `headSha` would do. Both are object ids, so the
    /// answer belongs to exactly those two commits. Nothing is written to the working
    /// tree or the index; `merge-tree` only adds objects.
    func mergePreview(headSha: String, sourceTipSha: String) async throws -> MergePreview {
        try Self.rejectOption(headSha, kind: "object id", command: "git rev-list")
        try Self.rejectOption(sourceTipSha, kind: "object id", command: "git rev-list")
        let counted = try await ProcessRunner.check(
            Self.executable,
            arguments: ["rev-list", "--count", "\(headSha)..\(sourceTipSha)"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        guard let commits = Int(counted.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProcessError.failed(
                command: "git rev-list --count", status: 0, stderr: "unreadable count: \(counted.stdoutString)")
        }
        if commits == 0 { return .alreadyMerged }

        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", headSha, sourceTipSha],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        // 1 is "merged with conflicts"; anything else non-zero is git failing to answer,
        // as for histories with no common ancestor.
        switch result.status {
        case 0: return .clean(commits: commits)
        case 1: return .conflicts(commits: commits, paths: MergeTreeParser.conflictedPaths(result.stdoutString))
        default:
            throw ProcessError.failed(
                command: "git merge-tree", status: result.status, stderr: result.stderrString)
        }
    }

    /// Up to `limit` commits that `sourceTipSha` brings in and `headSha` lacks, newest
    /// first. Follows every parent, not only the first, so the list agrees with the count
    /// `mergePreview` reports.
    func commitsToMerge(headSha: String, sourceTipSha: String, limit: Int) async throws -> [CommitSummary] {
        // Git reads a negative count as no limit at all.
        guard limit > 0 else { return [] }
        try Self.rejectOption(headSha, kind: "object id", command: "git log")
        try Self.rejectOption(sourceTipSha, kind: "object id", command: "git log")
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: [
                "log", "-z", "--max-count=\(limit)", "--format=%H%x00%h%x00%P%x00%cI%x00%an%x00%s",
                sourceTipSha, "--not", headSha,
            ],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return try GitLogParser.parse(result.stdout)
    }

    /// Merges exactly `sourceTipSha`, the commit the reader confirmed, so a ref that a
    /// fetch has moved since can't bring in commits the sheet never showed. `sourceRef`, a
    /// full ref such as `refs/heads/x` or `refs/remotes/origin/x`, only names the branch
    /// in the message. Runs hooks, so it takes the hook environment.
    func merge(sourceTipSha: String, sourceRef: String) async throws {
        try Self.rejectOption(sourceTipSha, kind: "object id", command: "git merge")
        try Self.rejectOption(sourceRef, kind: "branch", command: "git merge")
        let message = try await mergeMessage(sourceTipSha: sourceTipSha, sourceRef: sourceRef)
        // Config decides fast-forward versus a merge commit, as in `pull()`; `--no-edit`
        // keeps a merge commit from opening `$EDITOR`. `--no-log` because the message
        // already has the shortlog `merge.log` asks for. Known cost: conflict markers are
        // labelled with the sha, since git labels them with the argument it was given.
        try await runReportingDiagnostics(
            ["merge", "--no-edit", "--no-log", "-m", message, sourceTipSha],
            command: "git merge", environment: await hookEnvironment())
    }

    /// The message `git merge <branch>` would write, from the same `git fmt-merge-msg`
    /// it uses, so branch naming, the "into <branch>" suffix and `merge.log` follow config.
    private func mergeMessage(sourceTipSha: String, sourceRef: String) async throws -> String {
        let description: String
        if sourceRef.hasPrefix("refs/heads/") {
            description = "branch '\(sourceRef.dropFirst("refs/heads/".count))'"
        } else if sourceRef.hasPrefix("refs/remotes/") {
            description = "remote-tracking branch '\(sourceRef.dropFirst("refs/remotes/".count))'"
        } else {
            description = "commit '\(sourceTipSha)'"
        }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "\(sourceTipSha)\t\t\(description) of .\n".write(to: input, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: input) }
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["fmt-merge-msg", "-F", input.path],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
