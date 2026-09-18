import Foundation

/// Suggested message from merge/squash metadata or commit.template, and whether a merge
/// is in progress.
struct CommitDefaults: Equatable, Sendable {
    struct Suggestion: Equatable, Sendable {
        enum Source: Sendable { case merge, squash, template }
        let text: String
        let source: Source
    }

    var suggestion: Suggestion?
    /// MERGE_HEAD exists; a merge may commit without staged differences.
    var isMerging: Bool

    static let none = CommitDefaults(suggestion: nil, isMerging: false)

    /// git's own precedence (`builtin/commit.c prepare_to_commit`): SQUASH_MSG followed by
    /// MERGE_MSG when both exist, else SQUASH_MSG, else MERGE_MSG, else commit.template.
    static func resolveMessage(merge: String?, squash: String?, template: String?) -> Suggestion? {
        if let squash {
            return Suggestion(text: squash + (merge ?? ""), source: .squash)
        }
        if let merge {
            return Suggestion(text: merge, source: .merge)
        }
        if let template {
            return Suggestion(text: template, source: .template)
        }
        return nil
    }
}
