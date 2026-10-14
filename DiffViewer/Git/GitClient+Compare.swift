import Foundation

/// The reads behind comparing two refs. Split from `GitClient.swift` to keep it under the
/// length lint.
extension GitClient {
    /// Every branch, remote-tracking branch and tag that resolves to a commit, in git's
    /// order. Sorting is the caller's job.
    func refs() async throws -> [GitRef] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: [
                "for-each-ref",
                "--format=%(refname)%00%(symref)%00%(objecttype)%00%(objectname)%00%(committerdate:unix)"
                    + "%00%(*objecttype)%00%(*objectname)%00%(*committerdate:unix)",
                "refs/heads/", "refs/remotes/", "refs/tags/",
            ],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return try GitRefParser.parse(result.stdoutString)
    }

    /// The best common ancestor of `first` and `second`, or nil when their histories share
    /// none.
    func mergeBase(_ first: String, _ second: String) async throws -> String? {
        try Self.rejectOption(first, kind: "object id", command: "git merge-base")
        try Self.rejectOption(second, kind: "object id", command: "git merge-base")
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["merge-base", first, second],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        // Exit 1 is "no common ancestor"; anything else non-zero is git failing to answer.
        if result.status == 1 { return nil }
        guard result.status == 0 else {
            throw ProcessError.failed(command: "git merge-base", status: result.status, stderr: result.stderrString)
        }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Files and lines that differ between the trees of `base` and `target`. Only a
    /// rename with identical content counts as one file; a renamed-and-edited file is a
    /// deletion plus an addition.
    func churn(base: String, target: String) async throws -> IncomingChangeSummary {
        try Self.rejectOption(base, kind: "object id", command: "git diff")
        try Self.rejectOption(target, kind: "object id", command: "git diff")
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["diff", "--shortstat", "--find-renames=100%", base, target, "--"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return try ShortstatParser.parse(result.stdoutString)
    }
}
