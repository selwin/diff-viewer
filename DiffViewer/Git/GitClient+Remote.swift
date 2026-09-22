import Foundation

/// The commands that talk to a remote: listing, fetch, pull, push. Split from
/// `GitClient.swift` to keep that file under the length lint.
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
    /// current.
    func fetch(remote: String) async throws {
        // Git itself would read a leading dash as an option.
        guard !remote.hasPrefix("-") else {
            throw ProcessError.failed(
                command: "git fetch", status: 128, stderr: "'\(remote)' is not a remote name")
        }
        // The remote's configured mappings decide which refs are updated, so the ref
        // `%(upstream:track)` compares against is the one refreshed whatever namespace it
        // lives in. Pruning is off: the fetch creates or moves refs and never deletes one,
        // so nothing a reader is looking at disappears underneath them. Tags may still be
        // auto-followed.
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["fetch", "--no-prune", "--no-prune-tags", remote],
            currentDirectory: repoRoot,
            environment: await remoteEnvironment()
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git fetch", status: result.status, stderr: Self.commandDiagnostics(result))
        }
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
}
