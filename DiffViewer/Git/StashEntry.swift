import Foundation

/// One entry of `git stash list`.
struct StashEntry: Sendable, Identifiable, Hashable {
    /// Added and deleted line counts of the stash's tracked changes.
    struct Churn: Sendable, Hashable {
        let additions: Int
        let deletions: Int
    }

    /// Position in this snapshot; changes when the stash reflog is reordered.
    let stashIndex: Int
    let sha: String
    let shortSha: String
    let parents: [String]
    let committedAt: Date
    let author: String
    /// What the user typed, or "WIP on <branch>" for git's default message.
    let message: String
    /// Nil for a detached HEAD or a message git did not write.
    let sourceBranch: String?
    let hasDefaultMessage: Bool
    /// Nil when the stat text cannot be read.
    let churn: Churn?

    /// Two entries can share a SHA (`git stash store`), so the SHA cannot be the id.
    var id: Int { stashIndex }
    var stashSelector: String { "stash@{\(stashIndex)}" }
    /// Whether the stash has a third parent for untracked or ignored files.
    var hasUntrackedParent: Bool { parents.count == 3 }

    /// Shown against its first parent, so the diff is the stash's tracked changes.
    var commitSummary: CommitSummary {
        CommitSummary(
            sha: sha, shortSha: shortSha, parents: parents, subject: message, committedAt: committedAt,
            author: author)
    }
}
