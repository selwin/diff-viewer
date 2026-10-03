import Foundation

/// A remote-tracking branch, as the last fetch left it.
struct RemoteBranch: Sendable, Equatable {
    /// The remote whose fetch mapping stores this ref: `origin`.
    let remote: String
    /// The branch name on that remote, from the mapping's source: `feature/x`.
    let name: String
    /// The full remote-tracking ref: `refs/remotes/origin/feature/x`.
    let ref: String
    /// The tip commit. A merge preview and its confirmation are pinned to it, so a fetch
    /// that moves the branch in between is noticed.
    let tipSha: String
    /// The tip commit's author, which says nothing about who owns the branch.
    let tipCommitAuthor: String
    /// The tip commit's committer date.
    let tipCommittedAt: Date
}
