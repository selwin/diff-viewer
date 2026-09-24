import Foundation

/// Parses `git diff-tree -r -z --name-status` output into a commit's changed files.
///
/// Each record is a status field followed by a path field: `M\0path\0A\0path\0`. A
/// rename or copy status carries a similarity score and is followed by *two* paths,
/// old then new.
/// Malformed records are skipped, matching `GitStatusParser` and `GitNumstatParser`.
enum GitNameStatusParser {
    static func parse(_ data: Data, area: ChangedFile.Area) -> [ChangedFile] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var files: [ChangedFile] = []
        var index = 0
        while index + 1 < fields.count {
            let status = fields[index]
            index += 1
            guard let letter = status.first, let kind = ChangedFile.Kind(rawValue: letter) else { continue }

            let path: String
            var originalPath: String?
            if kind == .renamed || kind == .copied {
                guard index + 1 < fields.count else { break }
                originalPath = fields[index]
                path = fields[index + 1]
                index += 2
            } else {
                path = fields[index]
                index += 1
            }

            guard !path.isEmpty else { continue }
            files.append(ChangedFile(path: path, originalPath: originalPath, kind: kind, area: area))
        }
        return files.sorted { $0.path < $1.path }
    }
}
