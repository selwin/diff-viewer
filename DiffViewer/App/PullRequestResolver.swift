import Foundation

/// Resolves a pull request to pinned commits: asks the remote, fetches, pins the
/// advertised SHAs and finds the comparison base. Holds no state.
@MainActor
struct PullRequestResolver {
    /// A failure after the advertisement, which carries the default branch the wording needs.
    struct Failure: Error {
        let advertised: AdvertisedPullRequest
        let underlying: any Error
    }

    let client: any RepoClient

    /// Throws `CancellationError` once `isCurrent()` turns false, so an obsolete request
    /// skips the steps after the one running. `onAdvertised` hears the remote's answer
    /// before the fetch, so the default branch can show while it runs.
    func resolve(
        _ request: PullRequestComparisonRequest, isCurrent: @MainActor () -> Bool,
        onAdvertised: @MainActor (AdvertisedPullRequest) -> Void
    ) async throws -> ResolvedPullRequest {
        try Self.check(isCurrent)
        let advertised = try await client.advertisedPullRequest(number: request.number, remote: request.remote)
        if isCurrent() { onAdvertised(advertised) }
        do {
            try Self.check(isCurrent)
            try await client.fetchPullRequest(advertised)
            try Self.check(isCurrent)
            try await client.pinAdvertisedCommits(advertised)
            try Self.check(isCurrent)
            let base = try await client.pullRequestBase(
                headSHA: advertised.headSHA, baseTipSHA: advertised.baseTipSHA)
            return ResolvedPullRequest(advertised: advertised, base: base)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Failure(advertised: advertised, underlying: error)
        }
    }

    private static func check(_ isCurrent: @MainActor () -> Bool) throws {
        guard isCurrent() else { throw CancellationError() }
    }
}
