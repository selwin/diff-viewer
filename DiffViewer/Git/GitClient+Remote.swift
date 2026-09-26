import Foundation

/// Remote commands: listing, fetch, pull, push, publish, fast-forward, and reading which
/// remote each branch tracks. Split from `GitClient.swift` to keep it under the length lint.
extension GitClient {
    /// Uses the hook environment and disables git's terminal credential prompts. Final:
    /// no override may turn prompting back on, since nobody is there to answer.
    private func remoteEnvironment() async -> [String: String] {
        var environment = await hookEnvironment()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }

    /// What a pull under `pull.rebase=interactive` would open. Git aborts the rebase
    /// cleanly when the sequence editor fails, leaving the branch untouched.
    private static let interactiveRebaseRefusal =
        "sh -c 'echo \"interactive rebase pulls are not supported by DiffViewer\" >&2; exit 1'"

    /// The names of the configured remotes, in git's order.
    func remoteNames() async throws -> [String] {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["remote"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return result.stdoutString.split(separator: "\n").map(String.init)
    }

    /// Updates the remote-tracking refs of `remote`, so the counts a branch reports are
    /// current, and prunes the ones whose remote branch is gone when that can touch
    /// nothing else.
    func fetch(remote: String) async throws {
        // Git itself would read a leading dash as an option.
        guard !remote.hasPrefix("-") else {
            throw ProcessError.failed(
                command: "git fetch", status: 128, stderr: "'\(remote)' is not a remote name")
        }
        // The remote's configured mappings decide which refs are updated, so the ref
        // `%(upstream:track)` compares against is the one refreshed whatever namespace it
        // lives in. Pruning is what makes a deleted remote branch read as gone, but it
        // deletes from every mapped destination, so it runs only when all of them are
        // remote-tracking refs. Tags are never pruned, and may still be auto-followed.
        let prune = FetchRefspecs.prunesOnlyTrackingRefs(try await fetchRefspecs(of: remote))
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["fetch", prune ? "--prune" : "--no-prune", "--no-prune-tags", remote],
            currentDirectory: repoRoot,
            environment: await remoteEnvironment()
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git fetch", status: result.status, stderr: Self.commandDiagnostics(result))
        }
    }

    /// The remote's `remote.<name>.fetch` mappings, in config order.
    private func fetchRefspecs(of remote: String) async throws -> [String] {
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["config", "-z", "--get-all", "remote.\(remote).fetch"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        // Status 1 is "no such key"; any other non-zero is a real config failure.
        if result.status == 1 { return [] }
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git config remote.\(remote).fetch", status: result.status, stderr: result.stderrString)
        }
        return result.stdoutString.split(separator: "\0").map(String.init)
    }

    /// Brings the current branch up to date with its upstream.
    func pull() async throws {
        // Config decides merge versus rebase; `--no-edit` keeps a merge from opening
        // `$EDITOR`, and the rebase path ignores it. An interactive rebase would still
        // open the sequence editor, so that editor is one that refuses.
        var environment = await remoteEnvironment()
        environment["GIT_SEQUENCE_EDITOR"] = Self.interactiveRebaseRefusal
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["pull", "--no-edit"],
            currentDirectory: repoRoot,
            environment: environment
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git pull", status: result.status, stderr: Self.commandDiagnostics(result))
        }
    }

    /// Sends `branch` to `remoteRef` on `remote`, fast-forward only.
    func push(branch: String, to remote: String, remoteRef: String) async throws {
        // Git itself would read a leading dash as an option.
        guard !branch.hasPrefix("-") else {
            throw ProcessError.failed(
                command: "git push", status: 128, stderr: "'\(branch)' is not a branch name")
        }
        guard !remote.hasPrefix("-") else {
            throw ProcessError.failed(
                command: "git push", status: 128, stderr: "'\(remote)' is not a remote name")
        }
        // An explicit refspec without a leading `+`, and no `--force`, is non-forcing
        // whatever `remote.<name>.push` or `push.default` say, so a push that would
        // discard someone else's commits is rejected instead. `--no-follow-tags` keeps
        // tags out of a branch push.
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["push", "--no-follow-tags", remote, "refs/heads/\(branch):\(remoteRef)"],
            currentDirectory: repoRoot,
            environment: await remoteEnvironment()
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git push", status: result.status, stderr: Self.commandDiagnostics(result))
        }
    }

    /// Pushes `branch` to `remote` under the same name and sets it as the upstream.
    /// Never forces, so a diverged remote branch rejects it.
    func publish(branch: String, to remote: String) async throws {
        // Git itself would read a leading dash as an option.
        guard !branch.hasPrefix("-") else {
            throw ProcessError.failed(
                command: "git push", status: 128, stderr: "'\(branch)' is not a branch name")
        }
        guard !remote.hasPrefix("-") else {
            throw ProcessError.failed(
                command: "git push", status: 128, stderr: "'\(remote)' is not a remote name")
        }
        // Explicit refspec with no `+` and no `--force`, as in `push`. `--set-upstream`
        // writes `branch.<b>.remote` and `.merge` even when the remote's fetch mapping
        // does not cover the new branch.
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: [
                "push", "--set-upstream", "--no-follow-tags", remote, "refs/heads/\(branch):refs/heads/\(branch)",
            ],
            currentDirectory: repoRoot,
            environment: await remoteEnvironment()
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git push", status: result.status, stderr: Self.commandDiagnostics(result))
        }
    }

    /// Moves `branch`, which must not be checked out, to the tip of `remoteRef` on
    /// `remote`, fast-forward only. `localRef` is the branch's upstream ref,
    /// `refs/remotes/...`; on success the branch equals it.
    func fastForward(branch: String, remote: String, remoteRef: String, localRef: String) async throws {
        // Git itself would read a leading dash as an option.
        guard !branch.hasPrefix("-") else {
            throw ProcessError.failed(
                command: "git fetch", status: 128, stderr: "'\(branch)' is not a branch name")
        }
        guard !remote.hasPrefix("-") else {
            throw ProcessError.failed(
                command: "git fetch", status: 128, stderr: "'\(remote)' is not a remote name")
        }
        // The first fetch force-writes `localRef`; outside `refs/remotes/` that could
        // overwrite a local branch.
        guard localRef.hasPrefix("refs/remotes/") else {
            throw ProcessError.failed(
                command: "git fetch", status: 128, stderr: "'\(localRef)' is not a remote-tracking ref")
        }
        // A symbolic ref would pass the prefix check yet write through to its target.
        let symbolic = try await ProcessRunner.run(
            Self.executable,
            arguments: ["symbolic-ref", "-q", localRef],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        if symbolic.status == 0 {
            throw ProcessError.failed(
                command: "git fetch", status: 128, stderr: "'\(localRef)' is a symbolic ref")
        }
        // Status 1 is "not symbolic", which includes a ref the fetch has yet to create.
        guard symbolic.status == 1 else {
            throw ProcessError.failed(
                command: "git symbolic-ref", status: symbolic.status, stderr: Self.commandDiagnostics(symbolic))
        }
        let environment = await remoteEnvironment()
        // One explicit refspec, so the upstream ref becomes the remote tip whatever the
        // remote's configured mappings cover.
        let fetch = try await ProcessRunner.run(
            Self.executable,
            arguments: ["fetch", "--no-prune", "--no-prune-tags", "--no-tags", remote, "+\(remoteRef):\(localRef)"],
            currentDirectory: repoRoot,
            environment: environment
        )
        guard fetch.status == 0 else {
            throw ProcessError.failed(
                command: "git fetch", status: fetch.status, stderr: Self.commandDiagnostics(fetch))
        }
        // Non-forced, so git refuses a non-fast-forward and a branch checked out in any
        // worktree rather than moving it.
        let update = try await ProcessRunner.run(
            Self.executable,
            arguments: ["fetch", ".", "\(localRef):refs/heads/\(branch)"],
            currentDirectory: repoRoot,
            environment: environment
        )
        guard update.status == 0 else {
            throw ProcessError.failed(
                command: "git fetch", status: update.status, stderr: Self.commandDiagnostics(update))
        }
    }

    /// The remote of every branch with an upstream configured, keyed by branch name. Unlike
    /// `localBranches`, it still names the remote when the fetch mapping does not cover
    /// the upstream and git reports no upstream at all.
    func configuredUpstreamRemotes() async throws -> [String: String] {
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["config", "-z", "--get-regexp", #"^branch\..+\.(remote|merge)$"#],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        // Status 1 is "no such key"; any other non-zero is a real config failure.
        if result.status == 1 { return [:] }
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git config branch.*", status: result.status, stderr: result.stderrString)
        }
        return Self.parseUpstreamRemotes(result.stdoutString)
    }

    /// Parses `key\nvalue\0` records, keeping branches with both `.remote` and `.merge`
    /// (a remote alone tracks nothing). The branch name is everything between `branch.`
    /// and the variable, so dots and case survive.
    static func parseUpstreamRemotes(_ output: String) -> [String: String] {
        var remotes: [String: String] = [:]
        var merging: Set<String> = []
        let prefix = "branch."
        for record in output.split(separator: "\0") {
            guard let newline = record.firstIndex(of: "\n") else { continue }
            let key = record[..<newline]
            let value = String(record[record.index(after: newline)...])
            for suffix in [".remote", ".merge"] {
                guard key.hasPrefix(prefix), key.hasSuffix(suffix), key.count > prefix.count + suffix.count else {
                    continue
                }
                let name = String(key.dropFirst(prefix.count).dropLast(suffix.count))
                if suffix == ".remote" { remotes[name] = value } else { merging.insert(name) }
            }
        }
        return remotes.filter { merging.contains($0.key) }
    }
}
