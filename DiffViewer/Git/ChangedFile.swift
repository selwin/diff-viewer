import Foundation

/// How many lines a file gained and lost. `nil` on a `ChangedFile` means unknown
/// (no numstat row, an unmerged path, or a file we could not read), which is not
/// the same as `.binary`, which is git saying the file has no line counts.
enum LineStats: Hashable, Sendable {
    case counted(added: Int, deleted: Int)
    case binary
}

/// One entry in the repository's change list. A path with both staged and unstaged
/// changes appears twice, once per area.
struct ChangedFile: Identifiable, Hashable, Sendable {
    enum Area: String, Sendable, CaseIterable {
        case unstaged
        case staged
    }

    enum Kind: Character, Sendable {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case typeChanged = "T"
        case untracked = "?"
        case unmerged = "U"

        var label: String {
            switch self {
            case .modified: "Modified"
            case .added: "Added"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .copied: "Copied"
            case .typeChanged: "Type changed"
            case .untracked: "Untracked"
            case .unmerged: "Conflict"
            }
        }
    }

    /// Path relative to the repository root, using the *new* name for renames.
    let path: String
    /// Original path for renames and copies.
    let originalPath: String?
    let kind: Kind
    let area: Area
    /// Added/deleted line counts, or nil while unknown. Last property so the
    /// memberwise initialiser keeps working without it.
    var lineStats: LineStats?

    var id: String { "\(area.rawValue):\(path)" }

    /// A copy carrying `lineStats`; the other fields are `let`.
    func with(lineStats: LineStats?) -> ChangedFile {
        var copy = self
        copy.lineStats = lineStats
        return copy
    }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}
