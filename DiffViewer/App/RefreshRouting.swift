import Foundation

/// What a batch of repository changes requires of a refresh.
struct RefreshWork: Equatable {
    /// The file list. Fingerprints keep the diff work that follows from repeating.
    var status: Bool
    /// Head state, local branches, and history if HEAD moved.
    var repositoryMetadata: Bool
    var commitDefaults: Bool

    static let none = RefreshWork(status: false, repositoryMetadata: false, commitDefaults: false)
}

/// Maps watcher changes to the refresh work they can affect, so an event drives only the
/// reads it can invalidate.
enum RefreshRouting {
    static func work(
        for changes: Set<RepoChange>, scope: DiffScope, template: CommitDefaults.TemplateDependency
    ) -> RefreshWork {
        guard !changes.isEmpty else { return .none }
        let inWorkingTree = scope == .workingTree
        // Configuration too: a branch's upstream lives there, and the title bar shows it.
        let metadata =
            changes.contains(.refs) || changes.contains(.rescan) || changes.contains(.configuration)

        // Every change can move the file list: a soft reset is `.refs` alone yet changes
        // what is staged, and `info/exclude` changes what is untracked.
        var work = RefreshWork(status: inWorkingTree, repositoryMetadata: metadata, commitDefaults: false)
        guard inWorkingTree else { return work }

        // Not `.index`: staging changes nothing the commit box prefills from. A worktree
        // write matters only when a template may live there; unknown is taken as may.
        work.commitDefaults =
            metadata || changes.contains(.commitState)
            || (changes.contains(.worktree) && template != .none)
        return work
    }
}
