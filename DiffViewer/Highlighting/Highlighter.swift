import Foundation
import SwiftTreeSitter

/// Syntax highlighting for one side of a diff: parses the full text with tree-sitter,
/// runs the grammar's highlight query, and returns per-line style runs plus the scope
/// outline built from the same parse.
enum Highlighter {
    /// Texts above this size are left unhighlighted to keep things snappy.
    static let maxBytes = 4_000_000

    struct Result: Sendable, Equatable {
        /// One entry per line.
        let runs: [[StyleRun]]
        let outline: ScopeOutline
    }

    static func highlight(lines: [String], fileName: String) -> Result? {
        guard !lines.isEmpty,
            let config = LanguageRegistry.configuration(forFileNamed: fileName),
            let query = config.queries[.highlights]
        else { return nil }
        return highlight(lines: lines, fileName: fileName, configuration: config, query: query)
    }

    /// Takes the query so a test can run one that matches nothing.
    static func highlight(lines: [String], fileName: String, highlightQuery query: Query) -> Result? {
        guard !lines.isEmpty, let config = LanguageRegistry.configuration(forFileNamed: fileName) else {
            return nil
        }
        return highlight(lines: lines, fileName: fileName, configuration: config, query: query)
    }

    /// Callers look up the configuration once and pass it in.
    private static func highlight(
        lines: [String], fileName: String, configuration config: LanguageConfiguration, query: Query
    ) -> Result? {
        guard let rules = LanguageRegistry.scopeRules(forFileNamed: fileName, configuration: config) else {
            return nil
        }

        let text = lines.joined(separator: "\n")
        guard text.utf8.count <= maxBytes else { return nil }

        let parser = Parser()
        do { try parser.setLanguage(config.language) } catch { return nil }
        PipelineMetrics.countParse()
        guard let tree = parser.parse(text) else { return nil }
        let outline = ScopeOutline.build(tree: tree, text: text, lines: lines, rules: rules)

        let spec = LanguageRegistry.spec(forFileNamed: fileName)
        let context = Predicate.Context(string: text)
        var painter = LinePainter(lines: lines)
        paint(
            captures(of: query, in: tree, context: context, precedence: spec?.precedence ?? .laterPatternWins),
            into: &painter)
        if spec?.highlightsInjections == true, let injectionQuery = config.queries[.injections] {
            // Painted after the host so injected captures win inside their ranges.
            paintInjections(of: injectionQuery, in: tree, text: text, context: context, into: &painter)
        }
        return Result(runs: painter.runs(), outline: outline)
    }

    private struct Capture {
        let start: Int
        let end: Int
        let pattern: Int
        let style: TokenStyle
    }

    /// Captures as UTF-16 ranges in tree-sitter precedence order: earlier start first,
    /// wider ranges before nested ones (so inner captures win), and for identical ranges
    /// the pattern the grammar's spec prefers (normally the later one, as in
    /// tree-sitter-highlight).
    private static func captures(
        of query: Query, in tree: MutableTree, context: SwiftTreeSitter.Predicate.Context,
        precedence: LanguageRegistry.Spec.Precedence
    ) -> [Capture] {
        let laterPatternWins = precedence != .earlierPatternWins
        var captures: [Capture] = []
        let cursor = query.execute(in: tree)
        while let match = cursor.next() {
            guard match.allowed(in: context) else { continue }
            for capture in match.captures {
                guard let name = capture.name,
                    let style = TokenStyle.paintStyle(forCaptureName: name)
                else { continue }
                let range = capture.range
                guard range.length > 0 else { continue }
                captures.append(
                    Capture(
                        start: range.location, end: range.location + range.length, pattern: match.patternIndex,
                        style: style))
            }
        }
        captures.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end > $1.end }
            return laterPatternWins ? $0.pattern > $1.pattern : $0.pattern < $1.pattern
        }
        return captures
    }

    /// For identical ranges only the first capture, the preferred one, paints.
    private static func paint(_ captures: [Capture], into painter: inout LinePainter) {
        var lastRange = (-1, -1)
        for capture in captures {
            if (capture.start, capture.end) == lastRange { continue }
            lastRange = (capture.start, capture.end)
            painter.paint(start: capture.start, end: capture.end, style: capture.style)
        }
    }

    /// A grammar an injection hands text to, with one parser reused for all its ranges.
    private struct InjectedLanguage {
        let parser: Parser
        let query: Query
        let precedence: LanguageRegistry.Spec.Precedence

        init?(spec: LanguageRegistry.Spec) {
            guard let config = LanguageRegistry.configuration(for: spec),
                let query = config.queries[.highlights]
            else { return nil }
            parser = Parser()
            do { try parser.setLanguage(config.language) } catch { return nil }
            self.query = query
            precedence = spec.precedence
        }
    }

    /// Lookahead per read when parsing an injection; tree-sitter asks again past it.
    private static let readChunkBytes = 64 * 1024

    /// Paints the highlight captures for each injection the host tree names, one level
    /// deep (an injected grammar's own injections are ignored). Each content node is
    /// parsed on its own, reading only its range of the document, so its captures keep
    /// document-wide offsets and emphasis cannot pair across paragraphs.
    private static func paintInjections(
        of injectionQuery: Query, in tree: MutableTree, text: String, context: SwiftTreeSitter.Predicate.Context,
        into painter: inout LinePainter
    ) {
        guard let utf16 = text.data(using: .utf16LittleEndian) else { return }
        var languages: [String: InjectedLanguage] = [:]
        let cursor = injectionQuery.execute(in: tree)
        while let match = cursor.next() {
            guard match.allowed(in: context),
                let injection = match.injection(with: context.textProvider),
                let content = match.captures(named: "injection.content").first?.node,
                let spec = LanguageRegistry.spec(forInjectionLanguage: injection.name)
            else { continue }
            if languages[spec.name] == nil {
                languages[spec.name] = InjectedLanguage(spec: spec)
            }
            guard let language = languages[spec.name] else { continue }
            let ranges = includedRanges(of: content)
            guard let last = ranges.last else { continue }

            language.parser.includedRanges = ranges
            let end = Int(last.bytes.upperBound)
            let injected = language.parser.parse(tree: nil as MutableTree?) { offset, _ in
                guard offset < end else { return nil }
                return utf16[offset..<min(end, offset + readChunkBytes)]
            }
            guard let injected else { continue }
            let found = captures(of: language.query, in: injected, context: context, precedence: language.precedence)
            paint(ranges.count == 1 ? found : clipped(found, to: ranges), into: &painter)
        }
    }

    /// An injected node can span the gaps between included ranges, such as emphasis that
    /// runs past a `> ` on the next line; only the parts inside the ranges paint.
    private static func clipped(_ captures: [Capture], to ranges: [TSRange]) -> [Capture] {
        let spans = ranges.map { Int($0.bytes.lowerBound / 2)..<Int($0.bytes.upperBound / 2) }
        var result: [Capture] = []
        result.reserveCapacity(captures.count)
        for capture in captures {
            // Binary search for the first span that ends after the capture starts.
            var low = 0
            var high = spans.count
            while low < high {
                let mid = (low + high) / 2
                if spans[mid].upperBound <= capture.start { low = mid + 1 } else { high = mid }
            }
            var index = low
            while index < spans.count, spans[index].lowerBound < capture.end {
                let start = max(capture.start, spans[index].lowerBound)
                let end = min(capture.end, spans[index].upperBound)
                if end > start {
                    result.append(Capture(start: start, end: end, pattern: capture.pattern, style: capture.style))
                }
                index += 1
            }
        }
        return result
    }

    /// The content node's range minus its named children, such as the `> ` and list
    /// indentation (`block_continuation`) inside a multi-line paragraph. Unnamed children
    /// stay in, unlike tree-sitter's default: Markdown's block grammar keeps punctuation
    /// as unnamed tokens inside `inline`, and the inline grammar needs it.
    private static func includedRanges(of node: Node) -> [TSRange] {
        var ranges: [TSRange] = []
        var startByte = node.byteRange.lowerBound
        var startPoint = node.pointRange.lowerBound
        func include(upTo byte: UInt32, _ point: Point) {
            if byte > startByte {
                ranges.append(TSRange(points: startPoint..<point, bytes: startByte..<byte))
            }
        }
        for index in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: index) else { continue }
            include(upTo: child.byteRange.lowerBound, child.pointRange.lowerBound)
            if child.byteRange.upperBound > startByte {
                startByte = child.byteRange.upperBound
                startPoint = child.pointRange.upperBound
            }
        }
        include(upTo: node.byteRange.upperBound, node.pointRange.upperBound)
        return ranges
    }

    /// Per-line style buffers addressed by document-wide UTF-16 offsets.
    struct LinePainter {
        private let lineStarts: [Int]
        private let lineLengths: [Int]
        private var buffers: [[UInt8]?]

        init(lines: [String]) {
            var starts: [Int] = []
            var lengths: [Int] = []
            starts.reserveCapacity(lines.count)
            lengths.reserveCapacity(lines.count)
            var offset = 0
            for line in lines {
                let length = line.utf16.count
                starts.append(offset)
                lengths.append(length)
                offset += length + 1
            }
            lineStarts = starts
            lineLengths = lengths
            buffers = Array(repeating: nil, count: lines.count)
        }

        private func line(containing offset: Int) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low
        }

        mutating func paint(start: Int, end: Int, style: TokenStyle) {
            guard !lineStarts.isEmpty, end > start else { return }
            var lineIndex = line(containing: start)
            var position = start
            while position < end, lineIndex < lineStarts.count {
                let lineStart = lineStarts[lineIndex]
                let lineEnd = lineStart + lineLengths[lineIndex]
                let from = max(position, lineStart)
                let to = min(end, lineEnd)
                if to > from {
                    if buffers[lineIndex] == nil {
                        buffers[lineIndex] = Array(repeating: 0, count: lineLengths[lineIndex])
                    }
                    for column in (from - lineStart)..<(to - lineStart) {
                        buffers[lineIndex]![column] = style.rawValue
                    }
                }
                position = lineEnd + 1
                lineIndex += 1
            }
        }

        func runs() -> [[StyleRun]] {
            buffers.map { buffer in
                guard let buffer else { return [] }
                var runs: [StyleRun] = []
                var index = 0
                while index < buffer.count {
                    let value = buffer[index]
                    var end = index + 1
                    while end < buffer.count, buffer[end] == value { end += 1 }
                    if value != 0, let style = TokenStyle(rawValue: value) {
                        runs.append(StyleRun(range: index..<end, style: style))
                    }
                    index = end
                }
                return runs
            }
        }
    }
}
