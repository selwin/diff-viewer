import Foundation

/// Where one side reads a change block's scope from. A block with a line on this side
/// reads that line. A block without one (an insertion seen from the old side, a deletion
/// from the new) reads the scope its neighbouring lines share.
enum ScopeAnchor: Sendable, Equatable {
    case line(Int)
    /// This side's lines just before and after the block; nil past the file's edge.
    case between(before: Int?, after: Int?)

    /// One anchor per block from `start` on. `sameSection` says whether two rows belong to
    /// the same file, so a neighbour in another changeset section is not used; that is also
    /// why an appended section never changes the anchors of the blocks before it.
    static func anchors(
        changeBlocks: [Range<Int>], startingAt start: Int = 0, rows: [DiffRow], side: DocumentSide,
        sameSection: (Int, Int) -> Bool
    ) -> [ScopeAnchor] {
        func line(ofRow row: Int) -> Int? {
            (side == .old ? rows[row].old : rows[row].new)?.lineIndex
        }
        func neighbour(_ row: Int, of block: Range<Int>) -> Int? {
            guard rows.indices.contains(row), sameSection(row, block.lowerBound) else { return nil }
            return line(ofRow: row)
        }
        return changeBlocks[start...].map { block in
            if let first = block.lazy.compactMap(line(ofRow:)).first { return .line(first) }
            return .between(
                before: neighbour(block.lowerBound - 1, of: block), after: neighbour(block.upperBound, of: block))
        }
    }

    /// The two innermost scope names at the line, outermost first, so a method reads with
    /// its type. For `.between` it is the scopes containing both neighbours, so a function
    /// inserted between two methods reads as their type.
    func names(in outline: ScopeOutline) -> [String] {
        let chain: [Int]
        switch self {
        case let .line(line):
            chain = outline.chain(atLine: line)
        case let .between(before?, after?):
            chain = zip(outline.chain(atLine: before), outline.chain(atLine: after)).prefix { $0 == $1 }.map(\.0)
        case .between:
            chain = []
        }
        return chain.suffix(2).map { outline.scopes[$0].name }
    }
}
