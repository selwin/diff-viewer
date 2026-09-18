import Foundation

/// Suggested message from merge/squash metadata or commit.template, and whether a merge
/// is in progress.
struct CommitDefaults: Equatable, Sendable {
    struct Suggestion: Equatable, Sendable {
        enum Source: Sendable { case merge, squash, template }
        let text: String
        let source: Source
    }

    /// Whether `commit.template` is configured. The dependency is the configuration, not the
    /// last suggestion: a configured template may live in the worktree, so a worktree write
    /// can change the suggestion even while the file is missing or outranked.
    enum TemplateDependency: Sendable, Equatable {
        /// Set to this absolute path, whether or not the file could be read. The watcher
        /// treats the path as a dependency, so a template kept under `.git` is not dropped
        /// with the rest of that directory's noise.
        case configured(path: String)
        case none
        /// The configuration could not be read.
        case unknown
    }

    var suggestion: Suggestion?
    /// MERGE_HEAD exists; a merge may commit without staged differences.
    var isMerging: Bool
    var templateDependency: TemplateDependency = .none

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
