import Foundation

/// The identity of one commit, and the revision it is compared against.
///
/// Equality and hashing use `sha` and `untrackedParentSHA`, never `shortSha`: git
/// lengthens abbreviations as a repository grows, so a refreshed ref must still compare
/// equal to the one a selection was made with, while a stash's view of a commit, which
/// adds its untracked files, must not equal the plain view of the same commit.
struct CommitRef: Sendable {
    /// The full object id.
    let sha: String
    /// The abbreviation git printed, for display only.
    let shortSha: String
    /// The commit this one is diffed against: its *first* parent, so a merge shows what
    /// it brought into the branch it was merged onto. Nil at a root commit, which has
    /// nothing before it.
    let firstParentSHA: String?
    /// A stash's third parent, a root commit holding the untracked or ignored files it
    /// saved. Nil for every other commit.
    let untrackedParentSHA: String?

    init(sha: String, shortSha: String, firstParentSHA: String?, untrackedParentSHA: String? = nil) {
        self.sha = sha
        self.shortSha = shortSha
        self.firstParentSHA = firstParentSHA
        self.untrackedParentSHA = untrackedParentSHA
    }

    /// The stash's untracked files as a root commit of their own, so they read as added
    /// files and their ids cannot collide with the stash's tracked ones.
    var untrackedCommit: CommitRef? {
        untrackedParentSHA.map { CommitRef(sha: $0, shortSha: String($0.prefix(7)), firstParentSHA: nil) }
    }
}

extension CommitRef: Hashable {
    static func == (lhs: CommitRef, rhs: CommitRef) -> Bool {
        lhs.sha == rhs.sha && lhs.untrackedParentSHA == rhs.untrackedParentSHA
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(sha)
        hasher.combine(untrackedParentSHA)
    }
}

/// One row of the commit picker: a commit's identity plus what the row shows.
struct CommitSummary: Sendable, Identifiable {
    let ref: CommitRef
    /// Every parent, in git's order. The first is the one `ref` compares against.
    let parents: [String]
    let subject: String
    /// The committer date, which dates and groups the rows, while `author` is the author
    /// name.
    let committedAt: Date
    let author: String

    /// Derives the ref from the parsed parents so the two can never disagree. Only a stash
    /// passes `untrackedParentSHA`: an octopus merge has a third parent too.
    init(
        sha: String, shortSha: String, parents: [String], subject: String, committedAt: Date, author: String,
        untrackedParentSHA: String? = nil
    ) {
        self.ref = CommitRef(
            sha: sha, shortSha: shortSha, firstParentSHA: parents.first, untrackedParentSHA: untrackedParentSHA)
        self.parents = parents
        self.subject = subject
        self.committedAt = committedAt
        self.author = author
    }

    var id: String { ref.sha }
    var isMerge: Bool { parents.count > 1 }
    var isRoot: Bool { parents.isEmpty }
}

/// Unlike `CommitRef`, a summary compares everything it displays, `shortSha` included,
/// so a refresh that lengthens git's abbreviation is seen as a change.
extension CommitSummary: Hashable {
    static func == (lhs: CommitSummary, rhs: CommitSummary) -> Bool {
        lhs.ref == rhs.ref
            && lhs.ref.shortSha == rhs.ref.shortSha
            && lhs.parents == rhs.parents
            && lhs.subject == rhs.subject
            && lhs.committedAt == rhs.committedAt
            && lhs.author == rhs.author
    }

    func hash(into hasher: inout Hasher) { hasher.combine(ref) }
}
