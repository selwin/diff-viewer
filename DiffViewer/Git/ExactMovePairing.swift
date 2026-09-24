import Foundation

/// Turns a plain `mv` back into one rename. Git only detects renames between entries it
/// tracks, so a move the index has not seen is an unstaged deletion plus an untracked
/// file. When the untracked file's raw blob id equals the deleted index blob, the two are
/// the same content and become one unstaged rename.
enum ExactMovePairing {
    /// What `GitClient.status` must size and hash before `apply` can pair anything.
    struct Candidates: Equatable {
        /// The deleted index blobs, unique and sorted.
        let deletedBlobIDs: [String]
        /// Untracked files that could match, by path, with their size on disk.
        let untrackedSizes: [String: Int64]
    }

    /// Nil when either side has nothing to offer, which is the common case and starts no
    /// process. Empty files are left out because every one matches every other, and a
    /// trailing `/` is a nested repository, not a file.
    static func candidates(in files: [ChangedFile]) -> Candidates? {
        let deleted = Set(files.compactMap { deletedBlobID(of: $0) })
        var untracked: [String: Int64] = [:]
        for file in files where file.area == .unstaged && file.kind == .untracked && !file.path.hasSuffix("/") {
            guard case let .file(_, _, size, _)? = file.fingerprint?.worktree, size > 0 else { continue }
            untracked[file.path] = size
        }
        guard !deleted.isEmpty, !untracked.isEmpty else { return nil }
        return Candidates(deletedBlobIDs: deleted.sorted(), untrackedSizes: untracked)
    }

    /// Replaces each deletion and untracked file with the same blob id by one unstaged
    /// rename. Within an id, pairs are one-to-one: a matching file name first (a move
    /// between folders), then path order. Leftovers stay as they were.
    static func apply(to files: [ChangedFile], rawBlobIDs: [String: String]) -> [ChangedFile] {
        var deletedByID: [String: [ChangedFile]] = [:]
        var untrackedByID: [String: [ChangedFile]] = [:]
        for file in files {
            if let oid = deletedBlobID(of: file) {
                deletedByID[oid, default: []].append(file)
            } else if file.area == .unstaged, file.kind == .untracked, let oid = rawBlobIDs[file.path] {
                untrackedByID[oid, default: []].append(file)
            }
        }

        // Keyed by the untracked row's path; the deleted row it absorbs is dropped.
        var renames: [String: ChangedFile] = [:]
        var absorbed: Set<String> = []
        for (oid, deleted) in deletedByID {
            guard let untracked = untrackedByID[oid] else { continue }
            for (old, new) in pairs(deleted, untracked) {
                renames[new.path] = rename(from: old, to: new)
                absorbed.insert(old.path)
            }
        }
        guard !renames.isEmpty else { return files }
        return files.compactMap { file in
            guard file.area == .unstaged else { return file }
            if file.kind == .deleted, absorbed.contains(file.path) { return nil }
            if file.kind == .untracked, let rename = renames[file.path] { return rename }
            return file
        }
    }

    /// The index blob of an unstaged deletion of a regular file, or nil for any other row.
    /// A symlink's blob is its target path and a gitlink's is a commit, so neither can be
    /// compared with a file's bytes.
    private static func deletedBlobID(of file: ChangedFile) -> String? {
        guard file.area == .unstaged, file.kind == .deleted,
            file.indexMode == "100644" || file.indexMode == "100755",
            case let .object(oid)? = file.fingerprint?.old
        else { return nil }
        return oid
    }

    /// One-to-one pairs among files with the same content: same file name first, then
    /// whatever is left in path order.
    private static func pairs(_ deleted: [ChangedFile], _ untracked: [ChangedFile]) -> [(ChangedFile, ChangedFile)] {
        let news = untracked.sorted { $0.path < $1.path }
        // Each name's untracked files in path order, and how many of them are taken.
        let byName = Dictionary(grouping: news, by: \.fileName)
        var taken: [String: Int] = [:]
        var used: Set<String> = []
        var unmatched: [ChangedFile] = []
        var result: [(ChangedFile, ChangedFile)] = []
        for old in deleted.sorted(by: { $0.path < $1.path }) {
            let next = taken[old.fileName, default: 0]
            if let group = byName[old.fileName], next < group.count {
                result.append((old, group[next]))
                taken[old.fileName] = next + 1
                used.insert(group[next].path)
            } else {
                unmatched.append(old)
            }
        }
        result += zip(unmatched, news.filter { !used.contains($0.path) })
        return result
    }

    /// The row a paired move becomes: the old side is the deleted index blob, read at the
    /// old path, and the new side is the untracked file on disk.
    private static func rename(from old: ChangedFile, to new: ChangedFile) -> ChangedFile {
        let fingerprint = DiffInputFingerprint(
            old: old.fingerprint?.old ?? .unknown, new: .notApplicable,
            worktree: new.fingerprint?.worktree ?? .unknown, kind: .renamed, originalPath: old.path)
        return ChangedFile(
            path: new.path, originalPath: old.path, kind: .renamed, area: .unstaged, fingerprint: fingerprint)
    }
}
