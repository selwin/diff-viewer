import Foundation

/// Why a pull request could not be turned into a comparison. Wording belongs to the caller.
enum PullRequestError: Error, Equatable, Sendable {
    /// The remote advertises no ref for the pull request.
    case notFound
    /// The remote's HEAD names no branch.
    case noDefaultBranch
    /// The advertised head or base tip is not in this repository after the fetch.
    case commitsUnavailable
    /// The head is part of the base and no earlier comparison base could be recovered.
    case alreadyInBase
    /// The head and the base share no history; `isShallow` says whether a shallow clone may be why.
    case noCommonHistory(isShallow: Bool)
}
