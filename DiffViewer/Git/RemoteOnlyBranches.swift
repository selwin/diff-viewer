import Foundation

/// The remote branches the picker lists beside the local ones.
enum RemoteOnlyBranches {
    /// Drops only the refs a local branch already tracks, which the local row stands for.
    /// A ref whose name matches an untracked local branch stays: checking it out is refused
    /// by name, not hidden.
    static func filter(remotes: [RemoteBranch], locals: [LocalBranch]) -> [RemoteBranch] {
        let tracked = Set(locals.compactMap { $0.upstream?.localRef })
        return remotes.filter { !tracked.contains($0.ref) }
    }
}
