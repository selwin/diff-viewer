import Foundation

/// Walking the current document's change blocks: ⌘↓ and ⌘↑, and the counter the header
/// draws from them.
///
/// An extension in its own file: the class body is long enough, and the two properties
/// this writes are `internal` so that it can. Nothing here reads the selection — whichever
/// document the loader published is the one being walked.
extension WindowState {
    /// The document navigation walks: one file's, or the whole changeset's.
    private var navigableDocument: DiffDocument? {
        switch diffLoader.content {
        case let .text(document): document
        case let .changeset(changeset): changeset.document
        default: nil
        }
    }

    var changeBlockCount: Int { navigableDocument?.changeBlocks.count ?? 0 }

    func nextChange() {
        jump(
            to: ChangeNavigator.next(
                after: ChangeNavigator.clamp(currentChangeIndex, count: changeBlockCount), count: changeBlockCount))
    }

    func previousChange() {
        jump(
            to: ChangeNavigator.previous(
                before: ChangeNavigator.clamp(currentChangeIndex, count: changeBlockCount), count: changeBlockCount))
    }

    private func jump(to index: Int?) {
        guard let index, let document = navigableDocument, index < document.changeBlocks.count else { return }
        currentChangeIndex = index
        scrollTarget = ScrollTarget(row: document.changeBlocks[index].lowerBound)
    }
}
