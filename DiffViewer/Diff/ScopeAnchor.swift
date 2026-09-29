import Foundation

/// Where one side reads a change block's scope from. A block with a line on this side
/// reads that line. A block without one (an insertion seen from the old side, a deletion
/// from the new) reads the scope its neighbouring lines share.
enum ScopeAnchor: Sendable, Equatable {
    case line(Int)
    /// This side's lines just before and after the block; nil past the file's edge.
    case between(before: Int?, after: Int?)

    /// One anchor per block from `start` on. A neighbour in another file (`sameSection` is
    /// false) is not used, which is also why appending a file never changes earlier anchors.
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

    /// Up to two innermost scope names, outermost first (`Cart`, `total`). For `.between`
    /// only scopes holding both neighbours count, so a method inserted between two others
    /// reads as their type.
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
