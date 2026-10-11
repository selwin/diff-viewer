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

    // MARK: Pop and drop

    /// Removes `entry` from the stash list once its selector still names the confirmed commit.
    ///
    /// Validation detects stale selections but is not atomic with reflog deletion;
    /// concurrent external stash writes can still change the selected entry.
    func drop(_ entry: StashEntry) async throws {
        let selector = try await validatedStashSelector(for: entry)
        try await runReportingDiagnostics(
            ["stash", "drop", selector], command: "git stash drop", environment: callEnvironment)
    }

    /// Applies the confirmed commit, then drops its entry. Applying by sha means a stash
    /// list that shifted meanwhile can never apply another stash's changes.
    ///
    /// Validation detects stale selections but is not atomic with reflog deletion;
    /// concurrent external stash writes can still change the selected entry.
    func pop(_ entry: StashEntry) async throws {
        // Apply would refuse anyway, and its own conflicts would then be indistinguishable.
        guard !(try await hasUnmergedPaths()) else { throw StashError.unresolvedConflicts }
        _ = try await validatedStashSelector(for: entry)
        do {
            try await runReportingDiagnostics(
                ["stash", "apply", entry.sha], command: "git stash apply", environment: await hookEnvironment())
        } catch {
            if (try? await hasUnmergedPaths()) == true { throw StashError.conflicts }
            throw error
        }
        try await dropAfterApply(entry)
    }

    /// Pop's last step, internal so tests can reach the gap between apply and drop. The
    /// changes are already in the working tree, so any failure must not read as "try again".
    func dropAfterApply(_ entry: StashEntry) async throws {
        do {
            try await drop(entry)
        } catch {
            throw StashError.appliedButNotDropped(underlying: error)
        }
    }

    /// `entry.stashSelector`, once it is checked to still name `entry.sha`. `-q` keeps a
    /// missing entry silent, so only a failure that says something is git's own.
    private func validatedStashSelector(for entry: StashEntry) async throws -> String {
        let selector = entry.stashSelector
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["rev-parse", "--verify", "-q", selector],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        if result.status == 0 {
            guard result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == entry.sha else {
                throw StashError.staleEntry
            }
            return selector
        }
        let diagnostics = Self.commandDiagnostics(result)
        guard diagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessError.failed(command: "git rev-parse", status: result.status, stderr: diagnostics)
        }
        throw StashError.staleEntry
    }

    private func hasUnmergedPaths() async throws -> Bool {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["diff", "--name-only", "--diff-filter=U"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return !result.stdout.isEmpty
    }
}

/// Why a pop or drop stopped short.
enum StashError: Error, LocalizedError {
    case staleEntry
    case unresolvedConflicts
    case conflicts
    case appliedButNotDropped(underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .staleEntry:
            return "The stash list changed. Refresh it and try again."
        case .unresolvedConflicts:
            return "Resolve the conflicts in Changes before popping a stash."
        case .conflicts:
            return "Pop left conflicts. The stash was kept. Resolve the conflicts before dropping it."
        case let .appliedButNotDropped(underlying):
            let message =
                "The changes were applied, but the stash could not be removed. Review Changes before dropping it."
            guard let detail = Self.diagnostics(of: underlying) else { return message }
            return message + "\n\n" + detail
        }
    }

    /// Git's own words, if any. Another `StashError` adds none: its advice would contradict this one's.
    private static func diagnostics(of error: any Error) -> String? {
        let detail: String
        switch error {
        case is StashError: return nil
        case let ProcessError.failed(_, _, stderr): detail = stderr
        default: detail = error.localizedDescription
        }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
