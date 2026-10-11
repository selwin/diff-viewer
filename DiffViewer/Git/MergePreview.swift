/// Predicted merge result for two commits; leaves the index and working tree unchanged.
enum MergePreview: Sendable, Equatable {
    /// The destination commit already contains the source.
    case alreadyMerged
    /// The source's `commits` merge without conflicts.
    case clean(commits: Int)
    /// The merge would stop on conflicts in `files`. Empty when git reported a conflict
    /// without naming a file, which is still a conflict.
    case conflicts(commits: Int, files: [MergeConflict])
}

/// A file the merge would stop on. `kind` summarizes the conflicts involving this path,
/// using the parser's fixed display priority.
struct MergeConflict: Sendable, Equatable {
    let path: String
    let kind: MergeConflictKind
}

enum MergeConflictKind: Sendable, Equatable {
    case contents
    case addAdd
    case modifyDelete
    case renameDelete
    case renameRename
    case fileDirectory
    /// A conflict git names with a type this app doesn't know, or none at all.
    case other
}

/// How much the source brings in: its changes since the merge base. An edit both
/// branches made still counts. Binary files count as files with no lines.
struct IncomingChangeSummary: Sendable, Equatable {
    let fileCount: Int
    let addedLineCount: Int
    let deletedLineCount: Int
}

extension MergePreview {
    /// How many commits the merge brings in; zero when already merged.
    var commitCount: Int {
        switch self {
        case .alreadyMerged: 0
        case let .clean(commits): commits
        case let .conflicts(commits, _): commits
        }
    }
}

/// Parses `git merge-tree --write-tree --name-only -z` (run with `LC_ALL=C`): the merged
/// tree's object id, each conflicted path, then one empty field. Message records follow,
/// `<N> <path1> … <pathN> <type> <message>`, every field terminated by NUL.
///
/// Types are merge-ort's short names: `Auto-merging`, `CONFLICT (contents)`,
/// `CONFLICT (binary)`, `CONFLICT (modify/delete)`, `CONFLICT (rename/delete)`,
/// `CONFLICT (rename/rename)`, `CONFLICT (file/directory)` and others. Add/add arrives as
/// `CONFLICT (contents)` with a message starting `CONFLICT (add/add)`. A record can name
/// paths that are not in the path section, such as the old name in a rename.
enum MergeTreeParser {
    /// Strongest first, so the result doesn't depend on record order.
    private static let priority: [MergeConflictKind] = [
        .modifyDelete, .renameDelete, .renameRename, .fileDirectory, .addAdd, .contents, .other,
    ]

    /// The conflicted files in git's order. Never split on newlines: a path may hold
    /// spaces, tabs and newlines, and `-z` is what keeps them unquoted.
    static func conflicts(_ output: String) -> [MergeConflict] {
        // Whatever follows the last NUL is unterminated, so a cut-off field is never read as whole.
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
            .dropFirst().dropLast().map(String.init)
        var seen = Set<String>()
        var paths: [String] = []
        var index = 0
        while index < fields.count, !fields[index].isEmpty {
            if seen.insert(fields[index]).inserted { paths.append(fields[index]) }
            index += 1
        }

        let kinds = kindsByPath(fields.dropFirst(index + 1), among: seen)
        return paths.map { MergeConflict(path: $0, kind: kinds[$0] ?? .other) }
    }

    /// Reads the message records. A malformed record ends the reading, since the rest
    /// can't be framed; the kinds read so far stay.
    private static func kindsByPath(_ fields: ArraySlice<String>, among paths: Set<String>) -> [String:
        MergeConflictKind]
    {
        var kinds: [String: MergeConflictKind] = [:]
        var index = fields.startIndex
        while index < fields.endIndex {
            // The record's N path fields, type and message must all be present. Compared
            // without adding to `count`, which a malformed record could make overflow.
            guard let count = Int(fields[index]), count > 0, count <= fields.endIndex - index - 3 else { break }
            let type = fields[index + count + 1]
            let message = fields[index + count + 2]
            if let kind = kind(type: type, message: message) {
                for path in fields[(index + 1)...(index + count)] where paths.contains(path) {
                    kinds[path] = stronger(kinds[path], kind)
                }
            }
            index += count + 3
        }
        return kinds
    }

    /// Nil for records that aren't conflicts, such as `Auto-merging`.
    private static func kind(type: String, message: String) -> MergeConflictKind? {
        switch type {
        case "CONFLICT (contents)": message.hasPrefix("CONFLICT (add/add)") ? .addAdd : .contents
        case "CONFLICT (binary)": .contents
        case "CONFLICT (modify/delete)": .modifyDelete
        case "CONFLICT (rename/delete)": .renameDelete
        case "CONFLICT (rename/rename)": .renameRename
        case "CONFLICT (file/directory)": .fileDirectory
        default: type.hasPrefix("CONFLICT") ? .other : nil
        }
    }

    private static func stronger(_ current: MergeConflictKind?, _ new: MergeConflictKind) -> MergeConflictKind {
        guard let current else { return new }
        let currentRank = priority.firstIndex(of: current) ?? priority.endIndex
        let newRank = priority.firstIndex(of: new) ?? priority.endIndex
        return newRank < currentRank ? new : current
    }
}
