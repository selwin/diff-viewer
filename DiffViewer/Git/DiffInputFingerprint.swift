import Foundation

/// What `DiffEngine.sources` will read for a file, as cheaply as git status and a stat
/// can describe it. A heuristic: equal fingerprints are assumed unchanged; `.unknown`
/// anywhere means revalidate.
///
/// The fields follow the engine's reads per area. Unstaged: the index blob (at the old
/// path for a rename) and the worktree file. Staged: the HEAD blob and the index blob. Untracked: the worktree file
/// alone. Unmerged: the engine reads HEAD, which status does not report, so `old` is
/// `.unknown`. Commit-scope files get no fingerprint at all; their content cannot change.
struct DiffInputFingerprint: Hashable, Sendable {
    /// One side that git holds: a blob in the index or at HEAD.
    enum Blob: Hashable, Sendable {
        /// The blob's object id, as porcelain v2 prints it.
        case object(String)
        /// Confirmed not there: the zero hash, meaning no entry on that side.
        case absent
        /// Status cannot say what the engine will read.
        case unknown
        /// Not an input for this area.
        case notApplicable
    }

    /// The file on disk, as `stat` describes it.
    enum Worktree: Hashable, Sendable {
        /// Metadata that moves on a likely content change, inode included for an atomic replace.
        case file(mtimeNs: Int64, ctimeNs: Int64, size: Int64, inode: UInt64)
        /// Confirmed absent (`ENOENT`).
        case missing
        /// `stat` failed for another reason.
        case unknown
        /// Not an input for this area.
        case notApplicable
    }

    let old: Blob
    let new: Blob
    let worktree: Worktree
    /// Part of the fingerprint because the engine's read depends on them.
    let kind: ChangedFile.Kind
    let originalPath: String?

    /// No `.unknown` in any field: only known, equal fingerprints permit reuse.
    var isKnown: Bool {
        old != .unknown && new != .unknown && worktree != .unknown
    }

    /// True when either side is nil or not known, or any field differs.
    static func mayHaveChanged(_ before: Self?, _ after: Self?) -> Bool {
        guard let before, let after, before.isKnown, after.isKnown else { return true }
        return before != after
    }

    /// A copy with the worktree filled in: the parser cannot stat, so `GitClient.status`
    /// does it afterwards.
    func with(worktree: Worktree) -> Self {
        Self(old: old, new: new, worktree: worktree, kind: kind, originalPath: originalPath)
    }

    /// Stats `url`, following symlinks: `GitClient.worktreeContents` reads the target, and
    /// the fingerprint describes what is displayed.
    static func worktree(at url: URL) -> Worktree {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            return errno == ENOENT ? .missing : .unknown
        }
        return .file(
            mtimeNs: nanoseconds(info.st_mtimespec),
            ctimeNs: nanoseconds(info.st_ctimespec),
            size: Int64(info.st_size),
            inode: UInt64(info.st_ino))
    }

    private static func nanoseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }
}
