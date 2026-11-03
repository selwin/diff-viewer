import Foundation

/// One pull request of a `/pulls` page, with its head repository's default branch.
struct PullRequestPageEntry: Equatable, Sendable {
    let pullRequest: ListedPullRequest
    /// Nil when the head repository was deleted.
    let headDefaultBranch: String?
}

/// Every pull request, open or not, of the base and head repositories, for the branch picker.
extension GitClient {
    /// Open pull requests are read in full, closed and merged ones from the newest page only:
    /// history is bounded, and the listing says whether the open part is complete.
    private enum PullRequestSource: CaseIterable {
        case open
        case closed

        var query: [(String, String)] {
            switch self {
            case .open: [("state", "open"), ("per_page", "100")]
            case .closed: [("state", "closed"), ("sort", "updated"), ("direction", "desc"), ("per_page", "100")]
            }
        }
    }

    /// Lists `base`, then `head` when it is another repository. A failed source adds no entries
    /// and marks the listing incomplete. Cancellation and rate limits propagate at once; if
    /// every source fails, throws the first error.
    func listPullRequests(head: GitHubRepository, base: GitHubRepository) async throws -> PullRequestListing {
        let token = try await resolveGitHubToken()?.value
        var repositories = [base]
        if !head.matches(base) { repositories.append(head) }

        var entries: [PullRequestPageEntry] = []
        var firstFailure: (any Error)?
        var anySucceeded = false
        var openSourcesSucceeded = true
        for repository in repositories {
            for source in PullRequestSource.allCases {
                do {
                    entries += try await pullRequestEntries(in: repository, source: source, token: token)
                    anySucceeded = true
                } catch {
                    // Another source can't be luckier: one is the user stopping, the other
                    // applies to every request.
                    if error is CancellationError { throw error }
                    if case GitHubAPIError.rateLimited = error { throw error }
                    firstFailure = firstFailure ?? error
                    if source == .open { openSourcesSucceeded = false }
                }
            }
        }
        if !anySucceeded, let firstFailure { throw firstFailure }
        return PullRequestListing(
            pullRequests: entries.map(\.pullRequest),
            headDefaultBranch: entries.first { $0.pullRequest.headRepository?.matches(head) == true }?
                .headDefaultBranch,
            allSourcesSucceeded: firstFailure == nil,
            openSourcesSucceeded: openSourcesSucceeded)
    }

    /// All of one source's pull requests, or a throw that discards any pages already read.
    private func pullRequestEntries(
        in repository: GitHubRepository, source: PullRequestSource, token: String?
    ) async throws -> [PullRequestPageEntry] {
        let path = "/repos/\(Self.pathComponent(repository.owner))/\(Self.pathComponent(repository.name))/pulls"
        switch source {
        case .open:
            var entries: [PullRequestPageEntry] = []
            try await gitHubAPI.forEachPage(path: path, query: source.query, token: token) { page in
                entries += try Self.parsePullRequestPage(page)
                return false
            }
            return entries
        case .closed:
            return try Self.parsePullRequestPage(
                try await gitHubAPI.get(path: path, query: source.query, token: token))
        }
    }

    /// The pull requests of one `/pulls` page, each decoded once. Throws
    /// `GitHubAPIError.unreadableResponse` for malformed JSON or dates, a state other than
    /// open or closed, or a non-https URL.
    static func parsePullRequestPage(_ data: Data) throws -> [PullRequestPageEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([ListedPullRequestObject].self, from: data).map { try $0.entry() }
        } catch {
            throw GitHubAPIError.unreadableResponse
        }
    }
}

/// The parts of a `/pulls` item the branch picker reads.
private struct ListedPullRequestObject: Decodable {
    let number: Int
    let state: String
    let draft: Bool?
    let mergedAt: Date?
    let updatedAt: Date
    let url: URL
    let head: ListedHeadObject

    enum CodingKeys: String, CodingKey {
        case number, state, draft, head
        case mergedAt = "merged_at"
        case updatedAt = "updated_at"
        case url = "html_url"
    }

    func entry() throws -> PullRequestPageEntry {
        let listedState: ListedPullRequest.State
        switch state {
        case "open": listedState = draft == true ? .draft : .open
        case "closed": listedState = mergedAt == nil ? .closed : .merged
        default: throw GitHubAPIError.unreadableResponse
        }
        // The URL is opened in a browser, so anything but a web page is refused.
        guard url.scheme?.lowercased() == "https" else { throw GitHubAPIError.unreadableResponse }
        let repository = head.repo.map { GitHubRepository(owner: $0.owner.login, name: $0.name) }
        return PullRequestPageEntry(
            pullRequest: ListedPullRequest(
                number: number, state: listedState, url: url, headBranch: head.ref, headRepository: repository,
                updatedAt: updatedAt),
            headDefaultBranch: head.repo?.defaultBranch)
    }
}

private struct ListedHeadObject: Decodable {
    let ref: String
    /// Null once the head repository is deleted.
    let repo: ListedHeadRepositoryObject?
}

private struct ListedHeadRepositoryObject: Decodable {
    struct Owner: Decodable {
        let login: String
    }

    let owner: Owner
    let name: String
    let defaultBranch: String?

    enum CodingKeys: String, CodingKey {
        case owner, name
        case defaultBranch = "default_branch"
    }
}
