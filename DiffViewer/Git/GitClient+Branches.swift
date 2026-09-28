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
        // Git itself would read a leading dash as an option.
        guard !name.hasPrefix("-") else {
            throw ProcessError.failed(command: "git switch", status: 128, stderr: "'\(name)' is not a branch name")
        }
        // `-c`, never `-C`: an existing branch is refused, not reset. `--no-track`: with
        // `branch.autoSetupMerge=inherit` or `always` the new branch would otherwise track
        // the branch it started from, and a push would go there.
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["switch", "--no-track", "-c", name],
            currentDirectory: repoRoot,
            environment: await hookEnvironment()
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git switch", status: result.status, stderr: Self.commandDiagnostics(result))
        }
    }
}
