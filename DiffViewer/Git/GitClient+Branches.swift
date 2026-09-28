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

    /// The commit `ref` resolves to, or nil when it names no commit. A name with a leading
    /// dash never reaches git, which would read it as an option.
    func commitSha(of ref: String) async throws -> String? {
        guard !ref.hasPrefix("-") else { return nil }
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        // `--quiet` promises exit 1 for a name that resolves to no commit.
        if result.status == 1 { return nil }
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git rev-parse --verify \(ref)", status: result.status, stderr: result.stderrString)
        }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The commits on `tip`'s first-parent chain that `upstreamTip` cannot reach.
    /// `--first-parent` narrows only what is listed: exclusion still follows every parent
    /// of the upstream, so a commit the upstream reached through a merge is not unpushed.
    func unpushedCommits(tip: String, upstreamTip: String) async throws -> Set<String> {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["rev-list", "--first-parent", tip, "--not", upstreamTip],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return Set(result.stdoutString.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// Every remote's `remote.<name>.fetch` values, in config order.
    private func fetchRefspecsByRemote() async throws -> [String: [String]] {
        let output = try await configOutput(
            ["-z", "--get-regexp", #"^remote\..+\.fetch$"#], command: "git config remote.*.fetch")
        return output.map(Self.parseFetchRefspecs) ?? [:]
    }

    /// Splits `-z --get-regexp` output into its `key\nvalue` records. A valueless key
    /// (`fetch` with no `=`) is printed without a newline and skipped; an empty value
    /// (`key\n`) is kept as "".
    static func configRecords(_ output: String) -> [(key: Substring, value: Substring)] {
        output.split(separator: "\0").compactMap { record in
            guard let newline = record.firstIndex(of: "\n") else { return nil }
            return (record[..<newline], record[record.index(after: newline)...])
        }
    }

    /// Parses `key\nvalue\0` records into values keyed by remote. The remote is everything
    /// between `remote.` and `.fetch`, so dots, slashes and case survive.
    static func parseFetchRefspecs(_ output: String) -> [String: [String]] {
        var refspecs: [String: [String]] = [:]
        let prefix = "remote."
        let suffix = ".fetch"
        for (key, value) in configRecords(output) {
            guard key.hasPrefix(prefix), key.hasSuffix(suffix), key.count > prefix.count + suffix.count else {
                continue
            }
            let remote = String(key.dropFirst(prefix.count).dropLast(suffix.count))
            refspecs[remote, default: []].append(String(value))
        }
        return refspecs
    }

    /// Creates `branch` from the remote-tracking ref `trackingRef` and switches to it. Git
    /// derives the upstream from the fetch mappings, and refuses a name that already exists
    /// locally rather than overwriting it. Runs the post-checkout hook, so it takes the
    /// hook environment.
    func checkoutTracking(branch: String, trackingRef: String) async throws {
        try Self.rejectOption(branch, kind: "branch name", command: "git switch")
        // Anything else could start a local branch that tracks nothing, or read as an option.
        guard trackingRef.hasPrefix("refs/remotes/") else {
            throw ProcessError.failed(
                command: "git switch", status: 128, stderr: "'\(trackingRef)' is not a remote-tracking ref")
        }
        // `-c`, never `-C`: the lowercase form refuses an existing branch instead of resetting it.
        try await runReportingDiagnostics(
            ["switch", "-c", branch, "--track", trackingRef], command: "git switch",
            environment: await hookEnvironment())
    }
}

// MARK: - New branches

extension GitClient {
    /// Whether git accepts `name` for a new local branch. A leading dash is refused without
    /// running git, which would read it as an option.
    func isValidBranchName(_ name: String) async throws -> Bool {
        guard !name.hasPrefix("-") else { return false }
        // The full ref, not `--branch`: that expands checkout shorthand, so `@{-1}` would
        // pass as the previous branch's name.
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["check-ref-format", "refs/heads/\(name)"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        // 1 is "not a valid name"; anything else non-zero is git failing to answer.
        switch result.status {
        case 0: return true
        case 1: return false
        default:
            throw ProcessError.failed(
                command: "git check-ref-format", status: result.status, stderr: result.stderrString)
        }
    }

    /// Creates `name` at HEAD and switches to it. Runs the post-checkout hook, so it takes
    /// the hook environment.
    func createBranch(_ name: String) async throws {
        try Self.rejectOption(name, kind: "branch name", command: "git switch")
        // `-c`, never `-C`: an existing branch is refused, not reset. `--no-track`: with
        // `branch.autoSetupMerge=inherit` or `always` the new branch would otherwise track
        // the branch it started from, and a push would go there.
        try await runReportingDiagnostics(
            ["switch", "--no-track", "-c", name], command: "git switch", environment: await hookEnvironment())
    }
}
