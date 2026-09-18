import Foundation

/// Parses `git status --porcelain=v2 -z` output into changed files.
///
/// Every entry carries a `DiffInputFingerprint` built from the record's blob hashes. The
/// parser cannot stat, so an unstaged entry's `worktree` is `.unknown` until
/// `GitClient.status` fills it in.
enum GitStatusParser {
    static func parse(_ data: Data) -> [ChangedFile] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var files: [ChangedFile] = []
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            guard let type = record.first else { continue }
            switch type {
            case "1":
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                files += entries(
                    xy: String(parts[1]), head: String(parts[6]), index: String(parts[7]),
                    path: String(parts[8]), originalPath: nil)
            case "2":
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10, index < fields.count else { continue }
                let originalPath = fields[index]
                index += 1
                files += entries(
                    xy: String(parts[1]), head: String(parts[6]), index: String(parts[7]),
                    path: String(parts[9]), originalPath: originalPath)
            case "u":
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                // The engine reads HEAD, and a "u" record gives the conflict stages instead,
                // so `old` stays unknown and a conflict is always revalidated.
                let fingerprint = DiffInputFingerprint(
                    old: .unknown, new: .notApplicable, worktree: .unknown, kind: .unmerged, originalPath: nil)
                files.append(
                    ChangedFile(
                        path: String(parts[10]), originalPath: nil, kind: .unmerged, area: .unstaged,
                        fingerprint: fingerprint))
            case "?":
                let path = String(record.dropFirst(2))
                let fingerprint = DiffInputFingerprint(
                    old: .absent, new: .notApplicable, worktree: .unknown, kind: .untracked, originalPath: nil)
                files.append(
                    ChangedFile(
                        path: path, originalPath: nil, kind: .untracked, area: .unstaged, fingerprint: fingerprint))
            default:
                continue
            }
        }
        return files
    }

    private static func entries(
        xy: String, head: String, index: String, path: String, originalPath: String?
    ) -> [ChangedFile] {
        var result: [ChangedFile] = []
        let chars = Array(xy)
        guard chars.count == 2 else { return result }
        if let kind = ChangedFile.Kind(rawValue: chars[0]), chars[0] != "." {
            let fingerprint = DiffInputFingerprint(
                old: blob(head), new: blob(index), worktree: .notApplicable, kind: kind, originalPath: originalPath)
            result.append(
                ChangedFile(
                    path: path, originalPath: originalPath, kind: kind, area: .staged, fingerprint: fingerprint))
        }
        if let kind = ChangedFile.Kind(rawValue: chars[1]), chars[1] != "." {
            // A staged rename with further worktree edits: the worktree change is to the new path.
            let fingerprint = DiffInputFingerprint(
                old: blob(index), new: .notApplicable, worktree: .unknown, kind: kind, originalPath: nil)
            result.append(
                ChangedFile(path: path, originalPath: nil, kind: kind, area: .unstaged, fingerprint: fingerprint))
        }
        return result
    }

    /// The zero hash means no entry on that side.
    private static func blob(_ hash: String) -> DiffInputFingerprint.Blob {
        hash.allSatisfy { $0 == "0" } ? .absent : .object(hash)
    }
}
