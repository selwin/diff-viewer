import Foundation

/// How each remote fared in the last finished fetch round.
struct FetchRound: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Fetched at this time: during the round, or earlier for a remote the cooldown skipped.
        case fetched(at: Date)
        case failed(message: String)
    }

    /// Every remote the round covered. A cooldown skip implies an earlier success, so each
    /// one has a time or an error.
    var outcomes: [String: Outcome] = [:]
    /// Why the remotes couldn't be listed, in which case nothing was fetched.
    var discoveryError: String?
}

/// A finished round waiting for the branch read that publishes it.
struct PendingFetchRound: Sendable {
    let round: FetchRound
    /// The remote-tracking refs read just before the fetches, or nil when that read failed.
    let before: Set<String>?
    /// The remotes whose fetch succeeded during the round; cooldown skips are not among them.
    let fetched: Set<String>
}

/// Which remote-tracking branches fetch rounds brought in, by full ref.
enum NewRemoteBranches {
    /// A remote fetched this round has its entries replaced by its refs missing from
    /// `before`; any other remote keeps its entries, so a failed fetch doesn't clear them.
    /// With no `before` nothing counts as new. A ref gone from `after` is dropped.
    static func update(
        previous: Set<String>, before: Set<String>?, after: [RemoteBranch], fetched: Set<String>
    ) -> Set<String> {
        let remoteByRef = Dictionary(after.map { ($0.ref, $0.remote) }, uniquingKeysWith: { first, _ in first })
        let carried = previous.filter { ref in remoteByRef[ref].map { !fetched.contains($0) } ?? false }
        guard let before else { return carried }
        let fresh = after.filter { fetched.contains($0.remote) && !before.contains($0.ref) }.map(\.ref)
        return carried.union(fresh)
    }
}
