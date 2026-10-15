import Foundation

/// The two revisions a fixed diff compares. A nil base is a root commit, compared
/// against the empty tree.
struct RevisionPair: Hashable, Sendable {
    let baseSHA: String?
    let targetSHA: String
}

extension CommitRef {
    var revisions: RevisionPair { RevisionPair(baseSHA: firstParentSHA, targetSHA: sha) }
}

/// What a three-dot comparison shows: `targetName`'s changes since its merge base with
/// `baseName`.
struct CommitRange: Sendable {
    /// Display only, never identity.
    let baseName: String
    let targetName: String
    let mergeBaseSHA: String
    let targetSHA: String

    var revisions: RevisionPair { RevisionPair(baseSHA: mergeBaseSHA, targetSHA: targetSHA) }
    var title: String { "\(baseName) … \(targetName)" }
}

/// Equality ignores the names. Fixed SHAs keep this tab unchanged when branch refs move.
extension CommitRange: Hashable {
    static func == (lhs: CommitRange, rhs: CommitRange) -> Bool {
        lhs.mergeBaseSHA == rhs.mergeBaseSHA && lhs.targetSHA == rhs.targetSHA
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(mergeBaseSHA)
        hasher.combine(targetSHA)
    }
}
