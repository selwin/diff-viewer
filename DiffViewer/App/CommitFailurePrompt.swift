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
