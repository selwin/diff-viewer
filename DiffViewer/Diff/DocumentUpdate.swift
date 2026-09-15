import Foundation

/// Which publication of which load a document came from. A single-file document has no
/// identity, which is why callers pass `nil` for one.
struct ChangesetIdentity: Hashable, Sendable {
    let loadID: UUID
    let revision: Int
}

/// How a newly published document relates to the one already installed. The decision is
/// made against what is installed, not against the last thing published, so a skipped
/// intermediate revision can never be mistaken for an extension of the installed one.
enum DocumentUpdate {
    enum Mode: Equatable, Sendable {
        /// The incoming document is the installed one plus sections at the end.
        case append
        /// The ordinary path: install the incoming document as a whole, as a single-file load does.
        case replace
    }

    static func mode(installed: ChangesetIdentity?, incoming: ChangesetIdentity?) -> Mode {
        guard let installed, let incoming else { return .replace }
        guard installed.loadID == incoming.loadID, incoming.revision > installed.revision else { return .replace }
        return .append
    }
}
