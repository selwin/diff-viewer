import Foundation

/// How many lines a file gained and lost. `nil` on a `ChangedFile` means unknown
/// (no numstat row, an unmerged path, or a file we could not read), which is not
/// the same as `.binary`, which is git saying the file has no line counts; a binary
/// file carries its byte counts instead, when they could be read.
enum LineStats: Hashable, Sendable {
    case counted(added: Int, deleted: Int)
    case binary(BinarySizes?)
}

/// The byte counts of a binary file's two sides. A nil side means that side does not
/// exist (an added or deleted file); a nil `BinarySizes` on `LineStats.binary` means the
/// counts could not be read. Git sides count the stored blob and the worktree side the
/// file on disk, so the two can differ under a clean/smudge filter.
struct BinarySizes: Hashable, Sendable {
    let oldByteCount: Int64?
    let newByteCount: Int64?
}

extension LineStats {
    /// The churn of a whole list: the sum of every `.counted` entry. Nil when nothing is
    /// counted yet — stats arrive after the list, and a binary-only or empty list has no
    /// line counts — so a caller can show the identity alone rather than "+0 −0". A path
    /// that is both staged and unstaged counts twice: those are two real diffs.
    static func total(of files: [ChangedFile]) -> LineStats? {
        var added = 0
        var deleted = 0
        var counted = false
        for file in files {
            guard case let .counted(a, d)? = file.lineStats else { continue }
            added += a
            deleted += d
            counted = true
        }
        return counted ? .counted(added: added, deleted: deleted) : nil
    }
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
    /// Added/deleted line counts, or a binary file's byte counts, or nil while unknown.
    var lineStats: LineStats?
    /// What the diff reads for this file, or nil for a commit, whose content cannot change.
    var fingerprint: DiffInputFingerprint?
    /// The index entry's mode, such as `100644` or `120000`. Set only on an unstaged
    /// deletion, where `ExactMovePairing` needs it: a symlink's blob is its target path.
    var indexMode: String?

    var id: String { "\(area.identity):\(path)" }

    /// A copy carrying `lineStats`; the other fields are `let`.
    func with(lineStats: LineStats?) -> ChangedFile {
        var copy = self
        copy.lineStats = lineStats
        return copy
    }

    /// A copy carrying `fingerprint`.
    func with(fingerprint: DiffInputFingerprint?) -> ChangedFile {
        var copy = self
        copy.fingerprint = fingerprint
        return copy
    }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}
