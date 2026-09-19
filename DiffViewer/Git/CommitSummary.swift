import Foundation

/// The identity of one commit, and the revision it is compared against.
///
/// Equality and hashing use `sha` alone: git lengthens abbreviations as a repository
/// grows, so a refreshed ref carrying a longer `shortSha` must still compare equal to
/// the one a selection was made with.
struct CommitRef: Sendable {
    /// The full object id.
    let sha: String
    /// The abbreviation git printed, for display only.
    let shortSha: String
    /// The commit this one is diffed against: its *first* parent, so a merge shows what
    /// it brought into the branch it was merged onto. Nil at a root commit, which has
    /// nothing before it.
    let firstParentSHA: String?
}

extension CommitRef: Hashable {
    static func == (lhs: CommitRef, rhs: CommitRef) -> Bool { lhs.sha == rhs.sha }

    func hash(into hasher: inout Hasher) { hasher.combine(sha) }
}

/// One line of the scope picker: a commit's identity plus what the menu shows.
struct CommitSummary: Sendable, Identifiable, Hashable {
    let ref: CommitRef
    /// Every parent, in git's order. The first is the one `ref` compares against.
    let parents: [String]
    let subject: String
    let authorName: String
    let authoredAt: Date

    /// Derives the ref from the parsed parents so the two can never disagree.
    init(sha: String, shortSha: String, parents: [String], subject: String, authorName: String, authoredAt: Date) {
        self.ref = CommitRef(sha: sha, shortSha: shortSha, firstParentSHA: parents.first)
        self.parents = parents
        self.subject = subject
        self.authorName = authorName
        self.authoredAt = authoredAt
    }

    var id: String { ref.sha }
    var isMerge: Bool { parents.count > 1 }
    var isRoot: Bool { parents.isEmpty }
}
