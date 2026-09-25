import Foundation

/// Finds the line of a failed commit's output that names what went wrong, so the alert can
/// lead with it instead of the hook's first line, which is usually `[WARNING]` chatter.
/// Pure, so the choice can be tested on real hook output.
enum CommitFailurePrompt {
    /// How strongly a line points at the failure.
    enum Rank {
        /// A file location, or an `error:` / `fatal:` diagnostic.
        case specific
        /// A bare "failed", "rejected" and the like: a hook that gave up without saying where.
        case generic
    }

    /// The longest subtitle; the output box below it holds the rest.
    private static let subtitleLimit = 160

    // Swift's `Regex` is not `Sendable`; these are built once and only ever read.
    nonisolated(unsafe) private static let csi = #/\x{1B}\[[0-?]*[ -\/]*[@-~]/#
    nonisolated(unsafe) private static let osc = #/\x{1B}\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)?/#
    nonisolated(unsafe) private static let otherEscape = #/\x{1B}[@-_]?/#
    /// pre-commit's `name.....Status` and `name.....(no files to check)Skipped`.
    nonisolated(unsafe) private static let dotLeader = #/^(.*[^.\s])\.{3,}((?:\([^)]*\))?[A-Za-z]+)\s*$/#
    /// `ProcessError`'s prefix; the first line of git's output follows it on the same line.
    nonisolated(unsafe) private static let statusPrefix = #/^(.+? exited with status -?\d+)(?::\s*|$)/#
    /// A zero count, removed before ranking so it cannot count as a failure on its own.
    nonisolated(unsafe) private static let zeroCount = #/\b(?:0 errors?|0 failures?|0 failed|no errors?)\b/#
        .wordBoundaryKind(.simple)
    /// pre-commit's status for a hook that did not fail.
    nonisolated(unsafe) private static let passedStatus = #/\b(?:Passed|Skipped)\s*$/#
    nonisolated(unsafe) private static let location = #/[\w.\/-]+\.[A-Za-z]\w*:\d+/#
    nonisolated(unsafe) private static let errorToken = #/\b(?:error|fatal):/#
        .ignoresCase().wordBoundaryKind(.simple)
    nonisolated(unsafe) private static let failureWord = #/\b(?:failed|failure|denied|rejected)\b/#
        .ignoresCase().wordBoundaryKind(.simple)

    /// Removes terminal color and cursor codes, which hooks print even into a pipe.
    static func strippingANSI(_ text: String) -> String {
        text.replacing(csi, with: "").replacing(osc, with: "").replacing(otherEscape, with: "")
    }

    /// Turns `swiftlint.....Failed` into `swiftlint: Failed`, leaving other lines alone.
    static func collapsingDotLeader(_ line: String) -> String {
        guard let match = line.wholeMatch(of: dotLeader) else { return line }
        return "\(match.1): \(match.2)"
    }

    /// The line's rank, or nil when it is not a diagnostic. A passed hook never ranks, and
    /// zero counts are ignored, so "0 failed" is not a failure but "failed: 0 errors" is.
    static func rank(_ line: String) -> Rank? {
        if line.contains(passedStatus) { return nil }
        let line = line.replacing(zeroCount, with: "")
        if line.contains(location) || line.contains(errorToken) { return .specific }
        if line.contains(failureWord) || line.contains("✗") { return .generic }
        return nil
    }

    /// The first specific diagnostic, else the first generic one, trimmed.
    static func failureLine(in message: String) -> String? {
        failureLine(among: parse(message).lines)
    }

    /// The alert's subtitle: the failure line; else the first line of output that is neither
    /// pre-commit's `[INFO]`/`[WARNING]` chatter nor a success summary; else git's exit status.
    static func fallback(for message: String) -> String {
        let (status, lines) = parse(message)
        let subtitle =
            failureLine(among: lines)
            ?? lines.first { !isNoise($0) && !isSuccess($0) }
            ?? status.map { $0 + "." }
            ?? "The commit failed."
        // The ellipsis counts toward the limit.
        return subtitle.count > subtitleLimit ? String(subtitle.prefix(subtitleLimit - 1)) + "…" : subtitle
    }

    // MARK: On-device summary

    /// System instructions for the on-device summary. About 80 characters fills one line of
    /// the alert. Files and lines go unmentioned: asked for them "if the output gives them",
    /// the model invented both for outputs that had none.
    static let instructions = """
        You explain why a git commit failed, given the output of git and its hooks. Reply \
        with one short, plain sentence: which hook or tool failed and why, using only facts \
        stated in the output. Aim for one line of about 80 characters; never exceed 110. \
        No markdown, no quotes, no preamble.
        """

    /// The output as the model sees it: cleaned, and cut to `budget` characters (newlines
    /// included) when longer. A cut keeps the diagnostics, a line of context around each,
    /// and then the end of the output, in their original order, with `[…]` for each gap.
    static func input(from output: String, budget: Int) -> String {
        let lines = strippingANSI(output)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { collapsingDotLeader(String($0)) }
        let cleaned = lines.joined(separator: "\n")
        guard cleaned.count > budget else { return cleaned }

        // Blank lines say nothing, so a cut never spends budget or context on them. A line
        // is clipped to a quarter of the budget, so even a single huge line leaves its start.
        let lineLimit = budget / 4
        var selection = LineSelection(
            lines: lines.filter { $0.contains { !$0.isWhitespace } }
                .map { $0.count > lineLimit ? String($0.prefix(lineLimit - 1)) + "…" : $0 })
        // Capped at half, so one early failure's lines never crowd out a later one.
        var diagnostics: [Int] = []
        var seen = Set<String>()
        for index in diagnosticOrder(selection.lines) {
            let (isNew, _) = seen.insert(selection.lines[index].trimmingCharacters(in: .whitespaces))
            if isNew, selection.keep(index, within: budget / 2) { diagnostics.append(index) }
        }
        for index in diagnostics.sorted() {
            for neighbor in [index - 1, index + 1] where selection.lines.indices.contains(neighbor) {
                _ = selection.keep(neighbor, within: budget)
            }
        }
        // A line too long for what is left is skipped, so shorter ones before it still fit.
        for index in selection.lines.indices.reversed() {
            _ = selection.keep(index, within: budget)
        }
        return selection.text
    }

    /// Diagnostic line indices in the order they claim budget: the first and the last
    /// specific ones, the other specific ones, then the same for generic ones. The ends
    /// come first because the first failure is usually the cause and the last the summary.
    private static func diagnosticOrder(_ lines: [String]) -> [Int] {
        let ranks = lines.map(rank)
        func endsFirst(_ rank: Rank) -> [Int] {
            let indices = lines.indices.filter { ranks[$0] == rank }
            guard let first = indices.first, let last = indices.last, first != last else { return indices }
            return [first, last] + indices.dropFirst().dropLast()
        }
        return endsFirst(.specific) + endsFirst(.generic)
    }

    /// The lines chosen for a cut input, and what they cost with their gap markers.
    private struct LineSelection {
        static let gapMarker = "[…]"

        let lines: [String]
        private var kept: [Bool]
        /// Characters of `text`, counting one newline per line and per marker.
        private var used = Self.gapMarker.count + 1

        init(lines: [String]) {
            self.lines = lines
            kept = Array(repeating: false, count: lines.count)
        }

        /// Keeps line `index` if the text stays within `limit`; true if it is kept now or
        /// already was. Keeping a line can split a gap in two or close one.
        mutating func keep(_ index: Int, within limit: Int) -> Bool {
            if kept[index] { return true }
            let droppedBefore = index > 0 && !kept[index - 1]
            let droppedAfter = index < lines.count - 1 && !kept[index + 1]
            let gapChange = (droppedBefore ? 1 : 0) + (droppedAfter ? 1 : 0) - 1
            let cost = lines[index].count + 1 + gapChange * (Self.gapMarker.count + 1)
            guard used + cost <= limit else { return false }
            used += cost
            kept[index] = true
            return true
        }

        var text: String {
            var result: [String] = []
            for index in lines.indices {
                if kept[index] {
                    result.append(lines[index])
                } else if index == 0 || kept[index - 1] {
                    result.append(Self.gapMarker)
                }
            }
            return result.joined(separator: "\n")
        }
    }

    /// The model's reply as one plain line: markdown and wrapping quotes removed, lines
    /// joined, whitespace collapsed, and clipped to the subtitle's limit.
    static func cleaned(_ reply: String) -> String {
        var text = reply.split(whereSeparator: \.isNewline)
            .map { $0.replacing(markdownLinePrefix, with: "") }
            .joined(separator: " ")
            .replacing(markdownEmphasis, with: "")
            .replacing(#/\s+/#, with: " ")
            .trimmingCharacters(in: .whitespaces)
        while let first = text.first, let last = text.last, text.count > 1,
            quotePairs.contains(where: { $0.open == first && $0.close == last })
        {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return clamped(text)
    }

    /// Headings, bullets and quote marks at the start of a reply's line.
    nonisolated(unsafe) private static let markdownLinePrefix = #/^\s*(?:#+|[-*•>]|\d+\.)\s+/#
    nonisolated(unsafe) private static let markdownEmphasis = #/\*\*|__|`/#
    private static let quotePairs: [(open: Character, close: Character)] = [
        ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"),
    ]

    /// `text` within the subtitle limit: through its last sentence end that fits, else cut
    /// at a word with "…". A sentence ends at `.`, `!` or `?` before whitespace, so the
    /// dot in `FindSideLabels.swift:24` or `v1.2` never ends one.
    private static func clamped(_ text: String) -> String {
        guard text.count > subtitleLimit else { return text }
        let characters = Array(text)
        // Longer than the limit, so every candidate has a character after it.
        let sentenceEnd = (0..<subtitleLimit).last { index in
            ".!?".contains(characters[index]) && characters[index + 1].isWhitespace
        }
        if let sentenceEnd { return String(characters[...sentenceEnd]) }
        // The ellipsis counts toward the limit.
        let head = characters[..<(subtitleLimit - 1)]
        let cut = head.lastIndex(where: \.isWhitespace).map { head[..<$0] } ?? head
        return String(cut).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func failureLine(among lines: [String]) -> String? {
        lines.first { rank($0) == .specific } ?? lines.first { rank($0) == .generic }
    }

    /// Splits off the `git commit exited with status N` prefix and returns the output's
    /// non-empty lines, cleaned and trimmed.
    private static func parse(_ message: String) -> (status: String?, lines: [String]) {
        var output = Substring(strippingANSI(message))
        var status: String?
        if let match = output.prefixMatch(of: statusPrefix) {
            status = String(match.1)
            output = output[match.range.upperBound...]
        }
        let lines = output.split(whereSeparator: \.isNewline)
            .map { collapsingDotLeader($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        return (status, lines)
    }

    private static func isNoise(_ line: String) -> Bool {
        line.hasPrefix("[INFO]") || line.hasPrefix("[WARNING]")
    }

    private static func isSuccess(_ line: String) -> Bool {
        line.contains(passedStatus) || line.contains(zeroCount)
    }
}
