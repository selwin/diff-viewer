import Foundation

/// What the panes show. `.file` folds with user state and the collapse-unchanged
/// preference; `.changeset` is a fixed projection from `ChangesetProjection`:
/// no fold state, no fold actions, no collapse toggle.
enum PaneContent {
    case file(DiffDocument)
    case changeset(ChangesetDocument)

    var document: DiffDocument {
        switch self {
        case let .file(document): document
        case let .changeset(changeset): changeset.document
        }
    }

    /// Nil for a file, which is why a file always installs as a replace.
    var identity: ChangesetIdentity? {
        switch self {
        case .file: nil
        case let .changeset(changeset): changeset.identity
        }
    }

    var changesetDocument: ChangesetDocument? {
        switch self {
        case .file: nil
        case let .changeset(changeset): changeset
        }
    }
}
