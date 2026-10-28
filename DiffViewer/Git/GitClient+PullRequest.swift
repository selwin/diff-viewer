import Foundation

/// Fetching a pull request and finding what to compare it against, with git alone.
/// Nothing here reads a mutable shared ref back: the SHAs `ls-remote` advertised are the
/// snapshot, and every later step takes them as arguments.
extension GitClient {
    /// Every ref this app writes for a pull request lives under this prefix.
    static func pullRequestRefPrefix(remote: String, number: Int) -> String {
        "refs/diffviewer/pull/\(remote)/\(number)"
    }

    /// The configured remotes, in git's order. `git remote get-url` applies `insteadOf`
    /// rewrites and lists the first URL when a remote has several.
    func remotes() async throws -> [GitRemote] {
        var remotes: [GitRemote] = []
        for name in try await remoteNames() {
            try Self.rejectOption(name, kind: "remote name", command: "git remote get-url")
            let result = try await ProcessRunner.check(
                Self.executable,
                arguments: ["remote", "get-url", name],
                currentDirectory: repoRoot,
                environment: callEnvironment
            )
            let url = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            remotes.append(GitRemote(name: name, fetchURL: url))
        }
        return remotes
    }

    /// Asks `remote` for its default branch and pull request `number`. The local
    /// `origin/HEAD` is never consulted, since it goes stale when the default branch changes.
    func advertisedPullRequest(number: Int, remote: String) async throws -> AdvertisedPullRequest {
        try Self.rejectOption(remote, kind: "remote name", command: "git ls-remote")
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["ls-remote", "--symref", remote, "HEAD", "refs/pull/\(number)/head"],
            currentDirectory: repoRoot,
            environment: try await remoteEnvironment()
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git ls-remote", status: result.status, stderr: Self.commandDiagnostics(result))
        }
        return try Self.parseAdvertisement(result.stdoutString, remote: remote, number: number)
    }

    /// Parses `ls-remote --symref` output: `ref: refs/heads/main<TAB>HEAD`, then
    /// `<sha><TAB>HEAD` and `<sha><TAB>refs/pull/<n>/head`. Refs are matched by exact name,
    /// because ls-remote patterns also match any ref that merely ends the same way.
    static func parseAdvertisement(_ output: String, remote: String, number: Int) throws -> AdvertisedPullRequest {
        var symref: Substring?
        var baseTip: String?
        var head: String?
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            if fields[0].hasPrefix("ref: ") {
                if fields[1] == "HEAD" { symref = fields[0].dropFirst("ref: ".count) }
            } else if isObjectID(String(fields[0])) {
                if fields[1] == "HEAD" { baseTip = String(fields[0]) }
                if fields[1] == "refs/pull/\(number)/head" { head = String(fields[0]) }
            }
        }
        guard let head else { throw PullRequestError.notFound }
        let branchPrefix = "refs/heads/"
        guard let symref, symref.hasPrefix(branchPrefix), symref.count > branchPrefix.count, let baseTip else {
            throw PullRequestError.noDefaultBranch
        }
        return AdvertisedPullRequest(
            remote: remote, number: number, defaultBranch: String(symref.dropFirst(branchPrefix.count)),
            baseTipSHA: baseTip, headSHA: head)
    }

    /// Every pull request head `remote` advertises, by head SHA, with the remote's own auth.
    func preferredPullRequestNumberByHeadSha(remote: String) async throws -> [String: Int] {
        try Self.rejectOption(remote, kind: "remote name", command: "git ls-remote")
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["ls-remote", remote, "refs/pull/*/head"],
            currentDirectory: repoRoot,
            environment: try await remoteEnvironment()
        )
        guard result.status == 0 else {
            throw ProcessError.failed(
                command: "git ls-remote", status: result.status, stderr: Self.commandDiagnostics(result))
        }
        return Self.parsePullRequestHeads(result.stdoutString)
    }

    /// Parses `<sha><TAB>refs/pull/<n>/head` lines, keeping only exact names: the pattern
    /// also matches refs that merely end the same way. For duplicate head SHAs, keep the
    /// highest PR number.
    static func parsePullRequestHeads(_ output: String) -> [String: Int] {
        let prefix = "refs/pull/"
        let suffix = "/head"
        var numbers: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].hasPrefix(prefix), fields[1].hasSuffix(suffix),
                fields[1].count > prefix.count + suffix.count
            else { continue }
            let digits = fields[1].dropFirst(prefix.count).dropLast(suffix.count)
            guard digits.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                let number = Int(digits), number > 0
            else { continue }
            let sha = String(fields[0])
            guard isObjectID(sha) else { continue }
            numbers[sha] = max(numbers[sha] ?? 0, number)
        }
        return numbers
    }

    private static func isObjectID(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }

    /// Fetches the pull request's head and the default branch into `refs/diffviewer/`.
    /// Those two refs only retain the latest tips; comparisons use the advertised SHAs.
    func fetchPullRequest(_ advertised: AdvertisedPullRequest) async throws {
        try Self.rejectOption(advertised.remote, kind: "remote name", command: "git fetch")
        try Self.rejectOption(advertised.defaultBranch, kind: "branch name", command: "git fetch")
        let prefix = Self.pullRequestRefPrefix(remote: advertised.remote, number: advertised.number)
        // An empty `--refmap` stops the remote's configured mappings from also updating its
        // tracking refs, and the no-prune flags override `fetch.prune` and `fetch.pruneTags`,
        // so this fetch touches nothing but the two refs named here.
        try await runReportingDiagnostics(
            [
                "fetch", "--no-tags", "--no-recurse-submodules", "--refmap=", "--no-prune", "--no-prune-tags",
                "--atomic", "--no-write-fetch-head", advertised.remote,
                "+refs/pull/\(advertised.number)/head:\(prefix)/head",
                "+refs/heads/\(advertised.defaultBranch):\(prefix)/base",
            ],
            command: "git fetch", environment: try await remoteEnvironment())
    }

    /// Checks that the advertised commits arrived, then pins each exact SHA under its own
    /// ref in one transaction. A force-push or a later fetch can move the head and base refs
    /// off these commits, and the pins keep them from a later `gc`.
    func pinAdvertisedCommits(_ advertised: AdvertisedPullRequest) async throws {
        try Self.rejectOption(advertised.remote, kind: "remote name", command: "git update-ref")
        for sha in [advertised.headSHA, advertised.baseTipSHA] {
            try Self.rejectOption(sha, kind: "object id", command: "git cat-file")
            guard Self.isObjectID(sha) else {
                throw ProcessError.failed(
                    command: "git update-ref", status: 128, stderr: "'\(sha)' is not an object id")
            }
            guard try await hasCommit(sha) else { throw PullRequestError.commitsUnavailable }
        }
        let prefix = Self.pullRequestRefPrefix(remote: advertised.remote, number: advertised.number)
        let transaction = [
            "start",
            "update \(prefix)/snapshots/\(advertised.headSHA) \(advertised.headSHA)",
            "update \(prefix)/base-tips/\(advertised.baseTipSHA) \(advertised.baseTipSHA)",
            "commit",
        ]
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffViewer-update-ref-\(UUID().uuidString)")
        try (transaction.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await ProcessRunner.check(
            Self.executable,
            arguments: ["update-ref", "--stdin"],
            currentDirectory: repoRoot,
            environment: callEnvironment,
            standardInput: file
        )
    }

    private func hasCommit(_ sha: String) async throws -> Bool {
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["cat-file", "-e", "\(sha)^{commit}"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return result.status == 0
    }

    /// The merge base of the head and the base tip. When that is the head itself, the base
    /// already contains the PR, so a merge commit that brought the head in may reveal where
    /// it forked. Squash and rebase merges leave a different merge base and never get here.
    func pullRequestBase(headSHA: String, baseTipSHA: String) async throws -> PullRequestComparisonBase {
        try Self.rejectOption(headSHA, kind: "object id", command: "git merge-base")
        try Self.rejectOption(baseTipSHA, kind: "object id", command: "git merge-base")
        guard let base = try await mergeBase(headSHA, baseTipSHA) else {
            throw PullRequestError.noCommonHistory(isShallow: try await isShallowRepository())
        }
        guard base == headSHA else { return PullRequestComparisonBase(commitSHA: base, isRecovered: false) }

        // The oldest first-parent commit of the base that has the head behind it is the one
        // that integrated it. It counts only if that merge introduced the head through a
        // non-first parent; a fast-forward or an unrelated merge leaves no earlier base to recover.
        let path = try await ProcessRunner.check(
            Self.executable,
            arguments: ["rev-list", "--first-parent", "--ancestry-path", "--reverse", "\(headSHA)..\(baseTipSHA)"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        guard let integration = path.stdoutString.split(separator: "\n").first.map(String.init) else {
            throw PullRequestError.alreadyInBase
        }
        let commit = try await ProcessRunner.check(
            Self.executable,
            arguments: ["rev-list", "--parents", "-n", "1", integration],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        let parents = commit.stdoutString.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
        guard parents.count >= 2, try await !isAncestor(headSHA, of: parents[0]) else {
            throw PullRequestError.alreadyInBase
        }
        guard let recovered = try await mergeBase(parents[0], headSHA) else {
            throw PullRequestError.noCommonHistory(isShallow: try await isShallowRepository())
        }
        return PullRequestComparisonBase(commitSHA: recovered, isRecovered: true)
    }

    private func isAncestor(_ commit: String, of descendant: String) async throws -> Bool {
        let result = try await ProcessRunner.run(
            Self.executable,
            arguments: ["merge-base", "--is-ancestor", commit, descendant],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        // Exit 1 is "not an ancestor"; anything else non-zero is git failing to answer.
        guard result.status == 0 || result.status == 1 else {
            throw ProcessError.failed(command: "git merge-base", status: result.status, stderr: result.stderrString)
        }
        return result.status == 0
    }

    private func isShallowRepository() async throws -> Bool {
        let result = try await ProcessRunner.check(
            Self.executable,
            arguments: ["rev-parse", "--is-shallow-repository"],
            currentDirectory: repoRoot,
            environment: callEnvironment
        )
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
}
