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

/// A fixed comparison between a base commit and a target commit. PR comparisons may recover
/// a comparison base from before integration.
struct CommitRange: Sendable {
    /// Display only, never identity.
    let baseName: String
    let targetName: String
    let mergeBaseSHA: String
    let targetSHA: String
    /// Display only, never identity: names the base when it isn't a plain merge base.
    let baseLabelOverride: String?

    init(
        baseName: String, targetName: String, mergeBaseSHA: String, targetSHA: String,
        baseLabelOverride: String? = nil
    ) {
        self.baseName = baseName
        self.targetName = targetName
        self.mergeBaseSHA = mergeBaseSHA
        self.targetSHA = targetSHA
        self.baseLabelOverride = baseLabelOverride
    }

    var revisions: RevisionPair { RevisionPair(baseSHA: mergeBaseSHA, targetSHA: targetSHA) }
    var title: String { "\(baseName) … \(targetName)" }
    var baseLabel: String { baseLabelOverride ?? "Merge base with \(baseName)" }
}

/// Equality ignores the names and labels. Fixed SHAs keep this tab unchanged when branch refs move.
extension CommitRange: Hashable {
    static func == (lhs: CommitRange, rhs: CommitRange) -> Bool {
        lhs.mergeBaseSHA == rhs.mergeBaseSHA && lhs.targetSHA == rhs.targetSHA
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(mergeBaseSHA)
        hasher.combine(targetSHA)
    }
}
