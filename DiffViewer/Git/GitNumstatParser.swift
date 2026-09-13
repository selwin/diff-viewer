import Foundation

/// One row of `git diff --numstat` output.
struct NumstatEntry: Hashable, Sendable {
    let path: String
    let stats: LineStats
}

/// Parses `git diff --numstat -z` output.
///
/// A normal record is `added\tdeleted\tpath\0`, a binary record is `-\t-\tpath\0`, and a
/// rename (only when rename detection is on) is `added\tdeleted\t\0old\0new\0`: the path
/// field is empty and the following two NUL-separated fields are the old and new paths.
/// Malformed records are skipped, never thrown, and parsing continues with the next one.
enum GitNumstatParser {
    static func parse(_ data: Data) -> [NumstatEntry] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var entries: [NumstatEntry] = []
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            // Only the first two tabs are separators; a path may itself contain tabs.
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }

            var path = String(parts[2])
            if path.isEmpty {
                // Rename framing: the old and new paths follow as their own fields.
                guard index + 1 < fields.count else { continue }
                path = fields[index + 1]
                index += 2
            }

            guard !path.isEmpty, let stats = stats(added: parts[0], deleted: parts[1]) else { continue }
            entries.append(NumstatEntry(path: path, stats: stats))
        }
        return entries
    }

    private static func stats(added: Substring, deleted: Substring) -> LineStats? {
        if added == "-" && deleted == "-" { return .binary }
        guard let added = Int(added), let deleted = Int(deleted) else { return nil }
        return .counted(added: added, deleted: deleted)
    }
}
