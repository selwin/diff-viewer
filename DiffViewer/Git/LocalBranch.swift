import Foundation

/// The remote branch a local branch tracks, and where the local branch stands against it.
struct BranchUpstream: Sendable, Equatable {
    /// What git shows the reader: `origin/main`.
    let shortName: String
    /// The remote the branch is configured against: `origin`.
    let remote: String
    /// The ref as it exists on the remote: `refs/heads/main`. A push names it explicitly.
    let remoteRef: String
    /// The local ref the counts compare against: `refs/remotes/origin/main`. A
    /// fast-forward of a branch that is not checked out fetches into it by name.
    let localRef: String
    let tracking: UpstreamTracking
}

/// A local branch and what git knows about the remote branch it tracks.
///
/// Counts come from the remote-tracking ref, so they are as old as the last fetch. The
/// app's fetch prunes when the remote's mappings store only remote-tracking refs, so a
/// deleted upstream branch reads as gone after the next fetch; a tracking ref missing
/// for any other reason reads the same.
struct LocalBranch: Sendable, Equatable {
    let name: String
    /// Nil when the branch tracks nothing.
    let upstream: BranchUpstream?
    /// The tip commit. A delete checks it, so a branch recreated under the same name at
    /// another commit is left alone.
    let tipSha: String
    /// The tip commit's committer date.
    let tipCommittedAt: Date
}

/// The state of a branch against its upstream, as `%(upstream:track)` reports it.
enum UpstreamTracking: Sendable, Equatable {
    /// `(0, 0)` is up to date.
    case counts(ahead: Int, behind: Int)
    /// The upstream ref no longer exists.
    case gone

    /// Parses git's `%(upstream:track,nobracket)` field: "", "gone", "ahead 7",
    /// "behind 2", or "ahead 1, behind 2". Unrecognised parts are ignored and a missing
    /// count is zero, so a surprise shows nothing rather than a wrong number.
    static func parse(_ field: String) -> UpstreamTracking {
        let field = field.trimmingCharacters(in: .whitespaces)
        if field == "gone" { return .gone }
        var ahead = 0
        var behind = 0
        for part in field.components(separatedBy: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            switch words[0] {
            case "ahead": ahead = count
            case "behind": behind = count
            default: break
            }
        }
        return .counts(ahead: ahead, behind: behind)
    }

    /// The words the branch picker shows after the name, or nil when there is nothing to
    /// say. Behind comes first: it is the one that decides whether a pull is due.
    var summary: String? {
        switch self {
        case .gone:
            // The branch is what is missing, not the remote.
            return "upstream gone"
        case let .counts(ahead, behind):
            var parts: [String] = []
            if behind > 0 { parts.append("\(behind) behind") }
            if ahead > 0 { parts.append("\(ahead) ahead") }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }
}
