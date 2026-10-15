import Foundation
import Observation

/// What the Compare window's Pull Request mode resolves: a pull request on one remote.
struct PullRequestComparisonRequest: Sendable, Equatable {
    let remote: String
    let repository: GitHubRepository
    let number: Int
}

/// The default branch the remote advertised for the current request. A separate object, so
/// the preview's stored resolver can write it without capturing the model.
@MainActor
@Observable
private final class AdvertisedDefaultBranch {
    var latest: String?
}

/// The Compare window's Pull Request mode: the pasted link, the remote it maps to, and a
/// preview that fetches the pull request and compares it with the remote's default branch.
@MainActor
@Observable
final class PullRequestCompareModel {
    enum RemoteList: Equatable {
        case loading
        case loaded([GitRemote])
        case failed(String)
    }

    var input = "" {
        didSet { revalidate() }
    }
    private(set) var remotes: RemoteList = .loading
    /// Nil while the input is empty, invalid, or waiting for the remotes.
    private(set) var request: PullRequestComparisonRequest?
    private(set) var inputError: String?
    /// Counts changes of `request`, so state kept for one request can't be mistaken for the
    /// same request entered again later.
    private(set) var requestGeneration = 0

    @ObservationIgnored private let client: any RepoClient
    @ObservationIgnored private let preview: ComparisonPreview<PullRequestComparisonRequest>
    @ObservationIgnored private let advertised: AdvertisedDefaultBranch
    @ObservationIgnored private var isClosed = false

    /// Longer than Branches mode: resolving fetches from the remote.
    static let debounceDelay = Duration.milliseconds(500)
    static let spinnerDelay = Duration.milliseconds(800)

    init(client: any RepoClient, clock: any Clock<Duration>) {
        self.client = client
        // The stored resolver captures only the resolver and the box, so the preview never
        // retains the model.
        let resolver = PullRequestResolver(client: client)
        let advertised = AdvertisedDefaultBranch()
        self.advertised = advertised
        preview = ComparisonPreview(
            client: client, clock: clock, debounce: Self.debounceDelay, spinnerDelay: Self.spinnerDelay
        ) { request, isCurrent in
            try await Self.range(for: request, resolver: resolver, isCurrent: isCurrent) { answer in
                advertised.latest = answer.defaultBranch
            }
        }
    }

    /// Exposed so tests can await them.
    var debounceTask: Task<Void, Never>? { preview.debounceTask }
    var readTask: Task<Void, Never>? { preview.readTask }

    var churn: ComparisonChurn { preview.churn }
    var resolution: ComparisonResolutionState { preview.resolution }
    var canCompare: Bool { request != nil }

    /// The current request's default branch, known once the remote answers.
    var defaultBranch: String? {
        if let latest = advertised.latest { return latest }
        if case let .resolved(range) = resolution { return range.baseName }
        return nil
    }

    // MARK: Loading

    /// A result that arrives after `close()` publishes nothing and starts no resolution.
    func loadRemotes() async {
        let loaded: RemoteList
        do {
            loaded = .loaded(try await client.remotes())
        } catch {
            loaded = .failed("Couldn't read this repository's remotes: \(error.localizedDescription)")
        }
        guard !isClosed else { return }
        remotes = loaded
        revalidate()
    }

    // MARK: Requests

    /// The preview ignores an equal request, so edits that keep the parsed request start no fetch.
    private func revalidate() {
        let previous = request
        (request, inputError) = match(input)
        if request != previous {
            requestGeneration += 1
            // Cleared so an answer for the earlier request can't show for this one. A stale
            // answer arriving later is not written: the resolver checks `isCurrent` first.
            advertised.latest = nil
        }
        preview.setRequest(request)
    }

    private func match(_ input: String) -> (PullRequestComparisonRequest?, String?) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, nil) }
        guard let parsed = PullRequestInput.parse(input) else { return (nil, "That isn't a pull request link.") }
        switch remotes {
        case .loading:
            return (nil, nil)
        case let .failed(message):
            return (nil, message)
        case let .loaded(list):
            do {
                let remote = try PullRequestRemote.choose(for: parsed, remotes: list)
                // Taken from the remote even for a link, so a case-only edit keeps the request.
                guard let repository = GitHubRepository.parse(remoteURL: remote.fetchURL) else {
                    return (nil, "No GitHub remote.")
                }
                let request = PullRequestComparisonRequest(
                    remote: remote.name, repository: repository, number: parsed.number)
                return (request, nil)
            } catch {
                switch error {
                case let .notARemote(repository):
                    let name = repository.fullName
                    return (nil, "This pull request is in \(name), which isn't a remote of this repository.")
                case .noGitHubRemote:
                    return (nil, "No GitHub remote.")
                }
            }
        }
    }

    /// Skips the debounce, for Return.
    func resolveNow() { preview.resolveNow() }

    func resolvedRange() async -> ComparisonOutcome? {
        await preview.resolvedRange()
    }

    func close() {
        isClosed = true
        preview.close()
    }

    // MARK: Adapter

    private static func range(
        for request: PullRequestComparisonRequest, resolver: PullRequestResolver, isCurrent: @MainActor () -> Bool,
        onAdvertised: @MainActor (AdvertisedPullRequest) -> Void
    ) async throws -> CommitRange {
        do {
            return commitRange(try await resolver.resolve(request, isCurrent: isCurrent, onAdvertised: onAdvertised))
        } catch {
            throw failure(error, for: request)
        }
    }

    private static func commitRange(_ resolved: ResolvedPullRequest) -> CommitRange {
        let name = "PR #\(resolved.advertised.number)"
        return CommitRange(
            baseName: resolved.advertised.defaultBranch, targetName: name, mergeBaseSHA: resolved.base.commitSHA,
            targetSHA: resolved.advertised.headSHA,
            baseLabelOverride: resolved.base.isRecovered ? "Comparison base for \(name)" : nil)
    }

    /// Typed errors get the model's wording; anything else, such as git's diagnostics or a
    /// cancellation, passes through.
    private static func failure(_ error: any Error, for request: PullRequestComparisonRequest) -> any Error {
        let failure = error as? PullRequestResolver.Failure
        guard let typed = (failure?.underlying ?? error) as? PullRequestError else {
            return failure?.underlying ?? error
        }
        let number = "#\(request.number)"
        let remote = request.remote
        let branch = failure?.advertised.defaultBranch ?? "the default branch"
        let message =
            switch typed {
            case .notFound: "Pull request \(number) wasn't found on \(remote)"
            case .noDefaultBranch: "\(remote) has no default branch"
            case .commitsUnavailable: "Couldn't get \(number)'s commits from \(remote). Try again."
            case .alreadyInBase:
                "\(number)'s commits are already in \(branch). A comparison base couldn't be recovered."
            case .noCommonHistory(isShallow: true): "This clone is shallow; fetch more history to compare."
            case .noCommonHistory(isShallow: false): "\(number) and \(branch) share no history."
            }
        return ComparisonFailure(message)
    }
}
