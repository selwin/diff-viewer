import Foundation

enum StashListParseError: Error, LocalizedError {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case let .malformed(detail): "git stash list returned unreadable output: \(detail)"
        }
    }
}

/// Parses `git stash list` written with the layout in `GitClient.stashes`: each record
/// is NUL, six NUL-terminated fields (sha, abbreviated sha, parents, committer date,
/// author name, reflog subject), then the `--shortstat` text of the stash's tracked
/// changes, which is empty or blank when there are none. Splitting on NUL therefore leaves an empty
/// first token and seven tokens per stash.
///
/// Framing is positional only, as in `GitLogParser`: git messages cannot contain NUL,
/// and a malformed group is an error rather than something to resynchronise on.
enum StashListParser {
    private static let tokensPerStash = 7

    static func parse(_ data: Data) throws -> [StashEntry] {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard tokens.removeFirst() == "" else {
            throw StashListParseError.malformed("output does not start with a record separator")
        }
        guard tokens.count.isMultiple(of: tokensPerStash) else {
            throw StashListParseError.malformed("\(tokens.count) fields is not a whole number of stashes")
        }

        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime]

        var entries: [StashEntry] = []
        for start in stride(from: 0, to: tokens.count, by: tokensPerStash) {
            let sha = tokens[start]
            guard GitLogParser.isObjectID(sha) else {
                throw StashListParseError.malformed("not an object id: \(sha.prefix(32))")
            }
            guard let committedAt = dates.date(from: tokens[start + 3]) else {
                throw StashListParseError.malformed("unreadable date: \(tokens[start + 3])")
            }
            let subject = parseSubject(tokens[start + 5])
            entries.append(
                StashEntry(
                    stashIndex: entries.count,
                    sha: sha,
                    shortSha: tokens[start + 1],
                    parents: tokens[start + 2].split(separator: " ").map(String.init),
                    committedAt: committedAt,
                    author: tokens[start + 4],
                    message: subject.message,
                    sourceBranch: subject.branch,
                    hasDefaultMessage: subject.isDefault,
                    churn: parseChurn(tokens[start + 6])
                ))
        }
        return entries
    }

    /// Reads the reflog subject git wrote: `On <branch>: <message>` for `stash push -m`,
    /// `WIP on <branch>: <sha> <subject>` for the default. Anything else, such as a
    /// message from `stash store -m`, is kept whole. A branch name cannot contain a
    /// colon, so the first `: ` ends it.
    static func parseSubject(_ subject: String) -> (message: String, branch: String?, isDefault: Bool) {
        func split(after prefix: String) -> (branch: String, rest: String)? {
            guard subject.hasPrefix(prefix) else { return nil }
            let body = subject.dropFirst(prefix.count)
            guard let colon = body.range(of: ": ") else { return nil }
            return (String(body[..<colon.lowerBound]), String(body[colon.upperBound...]))
        }
        func named(_ branch: String) -> String? { branch == "(no branch)" ? nil : branch }

        if let parts = split(after: "On ") { return (parts.rest, named(parts.branch), false) }
        if let parts = split(after: "WIP on ") { return ("WIP on \(parts.branch)", named(parts.branch), true) }
        return (subject, nil, false)
    }

    /// Reads `N files changed[, X insertions(+)][, Y deletions(-)]`. Blank text is a stash
    /// with no tracked changes, and any other text is nil rather than a guess.
    static func parseChurn(_ stat: String) -> StashEntry.Churn? {
        let stat = stat.trimmingCharacters(in: .whitespacesAndNewlines)
        if stat.isEmpty { return StashEntry.Churn(additions: 0, deletions: 0) }
        let pattern = #/\d+ files? changed(?:, (\d+) insertions?\(\+\))?(?:, (\d+) deletions?\(-\))?/#
        guard let match = stat.wholeMatch(of: pattern) else { return nil }
        return StashEntry.Churn(
            additions: match.output.1.flatMap { Int($0) } ?? 0, deletions: match.output.2.flatMap { Int($0) } ?? 0)
    }

    /// Reads the `git log --format=%x00%H --shortstat` that `GitClient.stashes` runs over
    /// third parents: each record is NUL, the sha and a newline, then the stat text. Returns
    /// the readable counts by sha; an unreadable stat is left out.
    static func parseUntrackedChurn(_ data: Data) throws -> [String: StashEntry.Churn] {
        var records = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard records.removeFirst() == "" else {
            throw StashListParseError.malformed("untracked stats do not start with a record separator")
        }
        var churn: [String: StashEntry.Churn] = [:]
        for record in records {
            let lines = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let sha = String(lines[0])
            guard GitLogParser.isObjectID(sha) else {
                throw StashListParseError.malformed("not an object id: \(sha.prefix(32))")
            }
            churn[sha] = parseChurn(lines.count > 1 ? String(lines[1]) : "")
        }
        return churn
    }
}
