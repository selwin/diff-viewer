import Foundation

/// What the branch picker reads beyond the local branches, and checking out a remote
/// branch. Split from `GitClient.swift` to keep it under the length lint.
extension GitClient {
    /// Remote-tracking branches sorted by ref name, without symbolic refs like `origin/HEAD`.
    func remoteBranches() async throws -> [RemoteBranch] {
        let refspecs = try await fetchRefspecsByRemote()
        // Same layout rules as `localBranches`: full ref names, NUL between fields.
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: [
                "for-each-ref",
                "--format=%(refname)%00%(symref)%00%(authorname)%00%(committerdate:iso-strict)",
                "refs/remotes/",
            ],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return try RemoteBranchParser.parse(result.stdoutString, refspecsByRemote: refspecs)
    }

    /// Every remote's `remote.<name>.fetch` values, in config order.
    private func fetchRefspecsByRemote() async throws -> [String: [String]] {
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["config", "-z", "--get-regexp", #"^remote\..+\.fetch$"#],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        // Status 1 is "no such key"; any other non-zero is a real config failure.
        if result.status == 1 { return [:] }
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git config remote.*.fetch", status: result.status, stderr: result.stderrString)
        }
        return Self.parseFetchRefspecs(result.stdoutString)
    }

    /// Parses `key\nvalue\0` records into values keyed by remote. The remote is everything
    /// between `remote.` and `.fetch`, so dots, slashes and case survive.
    static func parseFetchRefspecs(_ output: String) -> [String: [String]] {
        var refspecs: [String: [String]] = [:]
        let prefix = "remote."
        let suffix = ".fetch"
        for record in output.split(separator: "\0") {
            // A key with no value has no newline and maps nothing.
            guard let newline = record.firstIndex(of: "\n") else { continue }
            let key = record[..<newline]
            guard key.hasPrefix(prefix), key.hasSuffix(suffix), key.count > prefix.count + suffix.count else {
                continue
            }
            let remote = String(key.dropFirst(prefix.count).dropLast(suffix.count))
            refspecs[remote, default: []].append(String(record[record.index(after: newline)...]))
        }
        return refspecs
    }

    /// Creates `branch` from the remote-tracking ref `trackingRef` and switches to it. Git
    /// derives the upstream from the fetch mappings, and refuses a name that already exists
    /// locally rather than overwriting it. Runs the post-checkout hook, so it takes the
    /// hook environment.
    func checkoutTracking(branch: String, trackingRef: String) async throws {
        // Git itself would read a leading dash as an option.
        guard !branch.hasPrefix("-") else {
            throw ProcessError.failed(
                command: "git switch", status: 128, stderr: "'\(branch)' is not a branch name")
        }
        // Anything else could start a local branch that tracks nothing, or read as an option.
        guard trackingRef.hasPrefix("refs/remotes/") else {
            throw ProcessError.failed(
                command: "git switch", status: 128, stderr: "'\(trackingRef)' is not a remote-tracking ref")
        }
        // `-c`, never `-C`: the lowercase form refuses an existing branch instead of resetting it.
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["switch", "-c", branch, "--track", trackingRef],
            currentDirectory: repoRoot,
            environment: await hookEnvironment()
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git switch", status: result.status, stderr: Self.commandDiagnostics(result))
        }
    }
}
