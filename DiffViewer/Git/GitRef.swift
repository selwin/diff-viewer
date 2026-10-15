import Foundation

/// A branch or tag and the commit it points at; an annotated tag carries its peeled commit.
struct GitRef: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case local
        case remote
        case tag
    }

    /// The full ref, such as `refs/remotes/origin/main`.
    let fullName: String
    /// The ref without its `refs/heads/`, `refs/remotes/` or `refs/tags/` prefix.
    let name: String
    let kind: Kind
    let commitSHA: String
    let committedAt: Date

    var id: String { fullName }
}

/// The order refs are offered in when choosing what to compare.
enum CompareRefOrdering {
    /// The current branch first, then other local branches, remote-tracking branches and
    /// tags. Newest commit first within a group; equal dates fall back to the full name so
    /// the order never shuffles between reloads. `currentBranch` is the short name.
    static func sorted(_ refs: [GitRef], currentBranch: String?) -> [GitRef] {
        func rank(_ ref: GitRef) -> Int {
            switch ref.kind {
            case .local: ref.name == currentBranch ? 0 : 1
            case .remote: 2
            case .tag: 3
            }
        }
        return refs.sorted { lhs, rhs in
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            if lhs.committedAt != rhs.committedAt { return lhs.committedAt > rhs.committedAt }
            return lhs.fullName < rhs.fullName
        }
    }
}
