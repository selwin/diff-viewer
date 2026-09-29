import Foundation
import SwiftTreeSitter
import TreeSitter

/// How a grammar node kind becomes a named scope (a function, method or type).
struct ScopeRule: Sendable {
    /// Where the scope's name comes from.
    enum NameSource: Sendable {
        /// A named field, optionally only when the field's node is one of `types`.
        case field(String, types: Set<String>? = nil)
        /// The first child of this node type, for grammars without fields.
        case childOfType(String)
        /// The innermost node reached by following `declarator` fields, as in C function definitions.
        case cDeclaratorIdentifier
        /// A fixed label, for nodes whose name field isn't a name.
        case fixed(String)
    }

    /// A field the node must have, optionally of one of `types`.
    struct Requirement: Sendable {
        let field: String
        let types: Set<String>?

        init(field: String, types: Set<String>? = nil) {
            self.field = field
            self.types = types
        }
    }

    let name: NameSource
    let requires: Requirement?

    init(name: NameSource, requires: Requirement? = nil) {
        self.name = name
        self.requires = requires
    }
}

/// A language's scope rules keyed by grammar symbol, so the tree walk compares integers
/// and only makes strings for scope nodes.
struct ScopeRules: Sendable {
    private let bySymbol: [ScopeRule?]

    /// A node kind can have several symbol IDs (aliases), so every named symbol with the
    /// kind's name gets the rule.
    init(_ rules: [String: ScopeRule], language: Language) {
        var bySymbol: [ScopeRule?] = []
        if !rules.isEmpty {
            let count = language.symbolCount
            bySymbol = Array(repeating: nil, count: count)
            for symbol in 0..<count {
                guard ts_language_symbol_type(language.tsLanguage, TSSymbol(symbol)) == TSSymbolTypeRegular,
                    let name = language.symbolName(for: symbol),
                    let rule = rules[name]
                else { continue }
                bySymbol[symbol] = rule
            }
        }
        self.bySymbol = bySymbol
    }

    var isEmpty: Bool { bySymbol.isEmpty }

    func rule(forSymbol symbol: Int) -> ScopeRule? {
        symbol >= 0 && symbol < bySymbol.count ? bySymbol[symbol] : nil
    }
}

/// The named scopes of one text, for finding the function or type a line belongs to.
struct ScopeOutline: Sendable, Equatable {
    struct Scope: Sendable, Equatable {
        /// Both ends are lines inside the scope.
        var lineRange: ClosedRange<Int>
        var name: String
        var parent: Int?
        /// Edge lines shared with other code are left to the enclosing scope.
        var claimsFirstLine: Bool
        var claimsLastLine: Bool

        func contains(line: Int) -> Bool {
            guard lineRange.contains(line) else { return false }
            if line == lineRange.lowerBound, !claimsFirstLine { return false }
            if line == lineRange.upperBound, !claimsLastLine { return false }
            return true
        }
    }

    /// Tree pre-order: parents before children, siblings in source order, so start lines
    /// never decrease.
    var scopes: [Scope] = []

    /// The name of the innermost scope containing the line.
    func name(atLine line: Int) -> String? {
        innermost(atLine: line).map { scopes[$0].name }
    }

    /// Indices of the scopes containing the line, outermost first.
    func chain(atLine line: Int) -> [Int] {
        var chain: [Int] = []
        var index = innermost(atLine: line)
        while let current = index {
            chain.append(current)
            index = scopes[current].parent
        }
        return chain.reversed()
    }

    /// Adds `other`, whose lines start at `lineOffset`, in place so joining many outlines stays linear.
    mutating func append(_ other: ScopeOutline, lineOffset: Int) {
        let base = scopes.count
        scopes.reserveCapacity(base + other.scopes.count)
        for scope in other.scopes {
            var shifted = scope
            shifted.lineRange = (scope.lineRange.lowerBound + lineOffset)...(scope.lineRange.upperBound + lineOffset)
            shifted.parent = scope.parent.map { $0 + base }
            scopes.append(shifted)
        }
    }

    /// The last scope starting at or before the line descends from the answer (or is it),
    /// so walking up its parents finds the innermost scope containing the line.
    private func innermost(atLine line: Int) -> Int? {
        var low = 0
        var high = scopes.count
        while low < high {
            let mid = (low + high) / 2
            if scopes[mid].lineRange.lowerBound <= line { low = mid + 1 } else { high = mid }
        }
        var index = low > 0 ? low - 1 : nil
        while let current = index {
            if scopes[current].contains(line: line) { return current }
            index = scopes[current].parent
        }
        return nil
    }
}

extension ScopeOutline {
    /// Walks the tree once. `text` is `lines` joined by "\n", as parsed; node ranges are
    /// UTF-16 offsets into it.
    static func build(tree: MutableTree, text: String, lines: [String], rules: ScopeRules) -> ScopeOutline {
        guard !rules.isEmpty, !lines.isEmpty, let root = tree.rootNode else { return ScopeOutline() }
        let builder = Builder(text: text as NSString, lines: lines)
        var outline = ScopeOutline()
        // Recorded scopes that enclose the cursor, with the tree depth they were found at.
        var open: [(depth: Int, index: Int)] = []
        let cursor = root.treeCursor
        var depth = 0
        while true {
            while let last = open.last, last.depth >= depth { open.removeLast() }
            if let node = cursor.currentNode, let rule = rules.rule(forSymbol: node.symbol),
                var scope = builder.scope(for: node, rule: rule)
            {
                scope.parent = open.last?.index
                open.append((depth, outline.scopes.count))
                outline.scopes.append(scope)
            }
            if cursor.goToFirstChild() {
                depth += 1
                continue
            }
            while !cursor.gotoNextSibling() {
                guard cursor.gotoParent() else { return outline }
                depth -= 1
            }
        }
    }

    private struct Builder {
        let text: NSString
        let lines: [String]

        func scope(for node: Node, rule: ScopeRule) -> Scope? {
            if let requirement = rule.requires {
                guard let child = node.child(byFieldName: requirement.field),
                    Self.matches(child, requirement.types)
                else { return nil }
            }
            guard let name = name(of: node, source: rule.name) else { return nil }

            let range = node.pointRange
            let startRow = Int(range.lowerBound.row)
            var endRow = Int(range.upperBound.row)
            // A node ending at column 0 ended with the previous line's newline.
            let endsWithNewline = range.upperBound.column == 0 && endRow > startRow
            if endsWithNewline { endRow -= 1 }
            guard startRow < lines.count else { return nil }
            endRow = min(endRow, lines.count - 1)

            let startColumn = Int(range.lowerBound.column) / 2
            let endColumn = Int(range.upperBound.column) / 2
            return Scope(
                lineRange: startRow...endRow,
                name: name,
                parent: nil,
                claimsFirstLine: onlyWhitespace(lines[startRow].utf16.prefix(startColumn)),
                claimsLastLine: endsWithNewline || onlyClosers(lines[endRow].utf16.dropFirst(endColumn))
            )
        }

        private func name(of node: Node, source: ScopeRule.NameSource) -> String? {
            let nameNode: Node?
            switch source {
            case .fixed(let label):
                return label
            case .field(let field, let types):
                nameNode = node.child(byFieldName: field).flatMap { Self.matches($0, types) ? $0 : nil }
            case .childOfType(let type):
                nameNode = (0..<node.childCount).lazy.compactMap { node.child(at: $0) }.first { $0.nodeType == type }
            case .cDeclaratorIdentifier:
                var current = node.child(byFieldName: "declarator")
                while let next = current?.child(byFieldName: "declarator") { current = next }
                nameNode = current
            }
            guard let nameNode else { return nil }
            let name = text.substring(with: nameNode.range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains(where: \.isNewline) else { return nil }
            return name
        }

        private static func matches(_ node: Node, _ types: Set<String>?) -> Bool {
            guard let types else { return true }
            return node.nodeType.map(types.contains) ?? false
        }

        private func onlyWhitespace(_ units: some Sequence<UTF16.CodeUnit>) -> Bool {
            units.allSatisfy(Self.isWhitespace)
        }

        /// Whitespace, `;` or `,` after a scope's end still leave its last line to it.
        private func onlyClosers(_ units: some Sequence<UTF16.CodeUnit>) -> Bool {
            units.allSatisfy { Self.isWhitespace($0) || $0 == 0x3B || $0 == 0x2C }
        }

        /// Surrogate halves are never whitespace, and no whitespace scalar is outside the BMP.
        private static func isWhitespace(_ unit: UTF16.CodeUnit) -> Bool {
            Unicode.Scalar(unit).map { $0.properties.isWhitespace } ?? false
        }
    }
}
