import Foundation

/// Parses `git status --porcelain=v2 -z` output into changed files.
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
                files += entries(xy: String(parts[1]), path: String(parts[8]), originalPath: nil)
            case "2":
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10, index < fields.count else { continue }
                let originalPath = fields[index]
                index += 1
                files += entries(xy: String(parts[1]), path: String(parts[9]), originalPath: originalPath)
            case "u":
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                files.append(ChangedFile(path: String(parts[10]), originalPath: nil, kind: .unmerged, area: .unstaged))
            case "?":
                let path = String(record.dropFirst(2))
                files.append(ChangedFile(path: path, originalPath: nil, kind: .untracked, area: .unstaged))
            default:
                continue
            }
        }
        return files
    }

    private static func entries(xy: String, path: String, originalPath: String?) -> [ChangedFile] {
        var result: [ChangedFile] = []
        let chars = Array(xy)
        guard chars.count == 2 else { return result }
        if let kind = ChangedFile.Kind(rawValue: chars[0]), chars[0] != "." {
            result.append(ChangedFile(path: path, originalPath: originalPath, kind: kind, area: .staged))
        }
        if let kind = ChangedFile.Kind(rawValue: chars[1]), chars[1] != "." {
            // A staged rename with further worktree edits: the worktree change is to the new path.
            result.append(ChangedFile(path: path, originalPath: nil, kind: kind, area: .unstaged))
        }
        return result
    }
}
