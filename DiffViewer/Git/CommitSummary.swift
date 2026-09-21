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

/// One row of the commit picker: a commit's identity plus what the row shows.
struct CommitSummary: Sendable, Identifiable {
    let ref: CommitRef
    /// Every parent, in git's order. The first is the one `ref` compares against.
    let parents: [String]
    let subject: String
    /// The committer timestamp, used for the picker's date labels.
    let committedAt: Date

    /// Derives the ref from the parsed parents so the two can never disagree.
    init(sha: String, shortSha: String, parents: [String], subject: String, committedAt: Date) {
        self.ref = CommitRef(sha: sha, shortSha: shortSha, firstParentSHA: parents.first)
        self.parents = parents
        self.subject = subject
        self.committedAt = committedAt
    }

    var id: String { ref.sha }
    var isMerge: Bool { parents.count > 1 }
    var isRoot: Bool { parents.isEmpty }
}

/// Unlike `CommitRef`, a summary compares everything it displays, `shortSha` included,
/// so a refresh that lengthens git's abbreviation is seen as a change.
extension CommitSummary: Hashable {
    static func == (lhs: CommitSummary, rhs: CommitSummary) -> Bool {
        lhs.ref.sha == rhs.ref.sha
            && lhs.ref.shortSha == rhs.ref.shortSha
            && lhs.parents == rhs.parents
            && lhs.subject == rhs.subject
            && lhs.committedAt == rhs.committedAt
    }

    func hash(into hasher: inout Hasher) { hasher.combine(ref) }
}
