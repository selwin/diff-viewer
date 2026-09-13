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
    /// Which pair of versions a file's diff comes from. The two working-tree cases are
    /// the areas git's status reports; `.commit` is one previous commit against its
    /// first parent.
    enum Area: Hashable, Sendable {
        case unstaged
        case staged
        case commit(CommitRef)

        /// The stable half of `ChangedFile.id`. Never derived from presentation, so
        /// reordering the sidebar can never change a selection. The two working-tree
        /// spellings match the raw values this enum used to have, which keeps existing
        /// ids — and `DIFFVIEWER_SELECT` — working.
        var identity: String {
            switch self {
            case .unstaged: "unstaged"
            case .staged: "staged"
            case let .commit(ref): "commit:\(ref.sha)"
            }
        }

        var isCommit: Bool {
            if case .commit = self { return true }
            return false
        }

        /// Sidebar and sort order only. Staged first, as the old lexical sort produced.
        var sortOrder: Int {
            switch self {
            case .staged: 0
            case .unstaged: 1
            case .commit: 2
            }
        }

        /// The two versions being compared, for the detail header.
        var comparisonLabel: String {
            switch self {
            case .unstaged: "Index → Working Tree"
            case .staged: "HEAD → Index"
            case let .commit(ref):
                ref.firstParentSHA == nil
                    ? "Empty tree → \(ref.shortSha)" : "\(ref.shortSha)^ → \(ref.shortSha)"
            }
        }
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

    var id: String { "\(area.identity):\(path)" }

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
