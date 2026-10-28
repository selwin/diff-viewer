import Foundation

/// Finding the pull request HEAD's branch already has, with git alone: GitHub advertises
/// each pull request's head commit as `refs/pull/<n>/head`, and one whose head is the
/// branch's remote-tracking tip is taken to be the branch's. Closed and merged pull requests
/// match too, while their advertised head still equals that tip.
///
/// A heuristic, with no GitHub API and no token. It matches by head commit only, so it
/// can't tell which branch a pull request came from. It searches the upstream's own remote,
/// plus a remote named `upstream` on another GitHub repository; pull requests anywhere else
/// go unseen. While another remote-tracking branch shares the tip it reports none, since
/// that branch may be the pull request's; the same branch on a remote with the same
/// repository doesn't count.
enum PullRequestLookup {
    /// Whether a remote-tracking branch other than the upstream itself, or its copy on a
    /// mirror remote, shares the key's tip.
    static func isAmbiguous(
        key: PullRequestLookupKey, remoteBranches: [RemoteBranch], mirrorRemotes: Set<String>
    ) -> Bool {
        remoteBranches.contains { branch in
            guard branch.tipSha == key.remoteTrackingTipSha else { return false }
            let isUpstreamCopy =
                branch.name == key.upstreamBranchName
                && (branch.remote == key.upstreamRemote || mirrorRemotes.contains(branch.remote))
            return !isUpstreamCopy
        }
    }

    /// The cached pull request, only while it describes the current key, the remote URLs
    /// last read for it, and an unambiguous tip.
    static func presentedResult(
        cache: PullRequestLookupCache?, key: PullRequestLookupKey?, observation: PullRequestLookupObservation?,
        remoteBranches: [RemoteBranch]
    ) -> PullRequestLookupResult? {
        guard let cache, let result = cache.result, let key, cache.key == key, let observation,
            observation.key == key, observation.configuration == cache.configuration,
            !isAmbiguous(key: key, remoteBranches: remoteBranches, mirrorRemotes: cache.configuration.mirrorRemotes)
        else { return nil }
        return result
    }
}

/// What a lookup is about: HEAD's branch, its upstream, and the remote-tracking tip a pull
/// request's head must match. A new tip is a new lookup.
struct PullRequestLookupKey: Hashable, Sendable {
    let branchName: String
    let upstreamRemote: String
    /// Under `refs/heads/`.
    let upstreamRemoteRef: String
    let remoteTrackingTipSha: String

    var upstreamBranchName: Substring { upstreamRemoteRef.dropFirst(Self.branchPrefix.count) }

    private static let branchPrefix = "refs/heads/"

    /// Nil unless the read loaded and HEAD's listed branch tracks a branch whose
    /// remote-tracking ref was read. Takes the branch state itself, not a snapshot, so a
    /// snapshot can be built from the key.
    static func make(
        headState: HeadState?, branches: [LocalBranch], remoteBranches: [RemoteBranch], readStatus: BranchReadStatus
    ) -> PullRequestLookupKey? {
        guard readStatus == .loaded, case let .named(name)? = headState,
            let upstream = branches.first(where: { $0.name == name })?.upstream, case .counts = upstream.tracking,
            upstream.remoteRef.hasPrefix(branchPrefix), upstream.remoteRef.count > branchPrefix.count,
            let tip = remoteBranches.first(where: { $0.ref == upstream.localRef })?.tipSha
        else { return nil }
        return PullRequestLookupKey(
            branchName: name, upstreamRemote: upstream.remote, upstreamRemoteRef: upstream.remoteRef,
            remoteTrackingTipSha: tip)
    }
}

/// What a key resolves to under the current remote URLs: the remotes to search, and the
/// remotes whose remote-tracking branches copy the upstream repository's.
struct PullRequestLookupConfiguration: Equatable, Sendable {
    let targets: [PullRequestLookupTarget]
    let mirrorRemotes: Set<String>

    static func make(key: PullRequestLookupKey, remotes: [String: RemoteURLs]) -> PullRequestLookupConfiguration {
        let targets = GitHubPullRequestLink.lookupTargets(for: key.upstreamRemote, remotes: remotes)
        let mirrors = targets.first.map { GitHubPullRequestLink.mirrorRemotes(of: $0.repository, remotes: remotes) }
        return PullRequestLookupConfiguration(targets: targets, mirrorRemotes: mirrors ?? [])
    }
}

/// A pull request found for a key.
struct PullRequestLookupResult: Equatable, Sendable {
    let number: Int
    let url: URL
}

/// The last lookup that finished conclusively: a match, or every target answering
/// without one.
struct PullRequestLookupCache: Equatable, Sendable {
    let key: PullRequestLookupKey
    /// The configuration the lookup searched with.
    let configuration: PullRequestLookupConfiguration
    let checkedAt: Date
    /// Nil when no target had a match.
    let result: PullRequestLookupResult?
}

/// The configuration a key last resolved to, from the latest remote-URL read.
struct PullRequestLookupObservation: Equatable, Sendable {
    let key: PullRequestLookupKey
    let configuration: PullRequestLookupConfiguration
}

/// The lookup running. Before it queries a remote, a remote-URL change is adopted rather
/// than replacing it.
struct PullRequestLookupFlight: Equatable, Sendable {
    let key: PullRequestLookupKey
    let ticket: Int
    var hasQueried = false
}
