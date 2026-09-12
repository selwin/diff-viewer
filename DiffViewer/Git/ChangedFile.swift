import Foundation

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

    var id: String { "\(area.rawValue):\(path)" }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}
