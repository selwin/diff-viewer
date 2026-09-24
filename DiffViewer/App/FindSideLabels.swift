import Foundation

/// What the find bar's scope segments and the pane headers call each side.
struct FindSideLabel: Equatable {
    enum Icon: Hashable {
        case branch
        case commit
        case workingTree
    }

    let title: String
    let icon: Icon?
}

/// Both sides' labels. Built from the same scope and HEAD the toolbar pickers read, so the
/// names match what the reader sees there.
struct FindSideLabels: Equatable {
    let old: FindSideLabel
    let new: FindSideLabel

    func label(for side: DocumentSide) -> FindSideLabel { side == .old ? old : new }

    static func make(scope: DiffScope, headState: HeadState?) -> FindSideLabels {
        switch scope {
        case .commit:
            return FindSideLabels(
                old: FindSideLabel(title: "Before", icon: nil), new: FindSideLabel(title: "After", icon: nil))
        case .workingTree:
            let old: FindSideLabel
            switch headState {
            case let .named(name): old = FindSideLabel(title: name, icon: .branch)
            case let .detached(sha): old = FindSideLabel(title: String(sha.prefix(7)), icon: .commit)
            // Not read yet: never shown as a detached HEAD.
            case nil: old = FindSideLabel(title: "HEAD", icon: nil)
            }
            return FindSideLabels(old: old, new: FindSideLabel(title: "Working Tree", icon: .workingTree))
        }
    }
}

/// The pane headers shown while find is open: both labels and the side being searched.
struct PaneFindScope: Equatable {
    let labels: FindSideLabels
    let searchedSide: DocumentSide
}
