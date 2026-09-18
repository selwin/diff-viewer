import CoreServices
import Foundation

/// What a filesystem event means to the app, coarsely enough to route the work.
enum RepoChange: Hashable, Sendable {
    case worktree
    case index
    case refs
    case commitState
    case configuration
    /// FSEvents lost track, or `.git` itself came or went: nothing can be assumed.
    case rescan
}

/// Sorts FSEvents paths into `RepoChange`s and drops the ones nothing shown depends on,
/// such as `.git/objects` and `.git/logs`, which git touches on every operation. A
/// configured dependency, such as a commit template kept under `.git`, is kept by path.
enum RepoEventFilter {
    private static let scanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagEventIdsWrapped)

    /// `root` is the symlink-resolved repository root without a trailing slash, matching
    /// how FSEvents reports paths, and `dependencies` are resolved paths the commit
    /// suggestion is read from. nil means the event is irrelevant and is dropped.
    static func classify(
        path: String, flags: FSEventStreamEventFlags, root: String, dependencies: Set<String> = []
    ) -> RepoChange? {
        if flags & scanFlags != 0 { return .rescan }

        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if dependencies.contains(path) { return .commitState }
        if path == root { return .worktree }
        guard path.hasPrefix(root + "/") else { return nil }
        let relative = path.dropFirst(root.count + 1)

        if relative == ".git" { return .rescan }
        // `.git/` with the slash, so `.gitignore` and `.github` stay worktree paths.
        if relative.hasPrefix(".git/") {
            return classifyMetadata(String(relative.dropFirst(".git/".count)))
        }
        switch relative.split(separator: "/").last {
        case ".gitignore", ".gitattributes": return .configuration
        default: return .worktree
        }
    }

    /// `rel` is the path inside `.git`.
    private static func classifyMetadata(_ rel: String) -> RepoChange? {
        switch rel {
        case "index": return .index
        case "HEAD", "packed-refs": return .refs
        case "MERGE_HEAD", "MERGE_MSG", "SQUASH_MSG", "CHERRY_PICK_HEAD", "REVERT_HEAD": return .commitState
        // `config.worktree` holds per-worktree settings under `extensions.worktreeConfig`.
        case "config", "config.worktree", "info/exclude", "info/attributes": return .configuration
        default: break
        }
        if rel.hasPrefix("refs/") { return .refs }
        // The directory itself too: starting or finishing a rebase creates or removes it.
        for state in ["rebase-merge", "rebase-apply"] where rel == state || rel.hasPrefix(state + "/") {
            return .commitState
        }
        return nil
    }
}
