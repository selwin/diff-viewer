import Foundation

enum ShortstatParseError: Error, LocalizedError {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case let .malformed(text): "git diff --shortstat returned unreadable output: \(text)"
        }
    }
}

/// Reads `git diff --shortstat`: `N files changed[, X insertions(+)][, Y deletions(-)]`,
/// or nothing at all when the trees match.
enum ShortstatParser {
    static func parse(_ output: String) throws -> IncomingChangeSummary {
        let stat = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if stat.isEmpty { return IncomingChangeSummary(fileCount: 0, addedLineCount: 0, deletedLineCount: 0) }
        let pattern = #/(\d+) files? changed(?:, (\d+) insertions?\(\+\))?(?:, (\d+) deletions?\(-\))?/#
        guard let match = stat.wholeMatch(of: pattern), let files = Int(match.output.1) else {
            throw ShortstatParseError.malformed(stat)
        }
        // A missing clause means zero; a present but unparseable count (overflow) is an error.
        func count(_ capture: Substring?) throws -> Int {
            guard let capture else { return 0 }
            guard let value = Int(capture) else { throw ShortstatParseError.malformed(stat) }
            return value
        }
        return IncomingChangeSummary(
            fileCount: files,
            addedLineCount: try count(match.output.2),
            deletedLineCount: try count(match.output.3))
    }
}
