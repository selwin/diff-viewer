import Foundation

enum GitLogParseError: Error, LocalizedError {
    case malformedFraming(fieldCount: Int)
    case notAnObjectID(String)
    case unreadableDate(String)

    var errorDescription: String? {
        switch self {
        case let .malformedFraming(count):
            "git log returned \(count) fields, which is not a whole number of commits"
        case let .notAnObjectID(field):
            "git log record did not start with an object id: \(field.prefix(32))"
        case let .unreadableDate(field):
            "git log returned an unreadable date: \(field)"
        }
    }
}

/// Parses `git log -z` written with the field layout in `GitClient.recentCommits`:
/// six NUL-separated fields per commit — sha, abbreviated sha, parents, author name,
/// author date, subject — with git's `-z` terminator after each commit.
///
/// Fields are read strictly positionally. There is deliberately no attempt to
/// resynchronise on a field that looks like an object id: a commit subject may itself
/// be exactly a valid object id, so guessing where records begin cannot be made safe.
/// Framing that does not divide into whole commits is an error, not something to
/// salvage — unlike the status and numstat parsers, where one malformed row among many
/// can be skipped without misattributing the rest.
enum GitLogParser {
    /// The lengths git's two object formats produce, SHA-1 and SHA-256.
    private static let objectIDLengths: Set<Int> = [40, 64]

    static func parse(_ data: Data) throws -> [CommitSummary] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // `-z` terminates the last commit too, leaving one empty field behind it.
        if fields.last == "" { fields.removeLast() }
        guard fields.count.isMultiple(of: 6) else {
            throw GitLogParseError.malformedFraming(fieldCount: fields.count)
        }

        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime]

        var commits: [CommitSummary] = []
        commits.reserveCapacity(fields.count / 6)
        for start in stride(from: 0, to: fields.count, by: 6) {
            let sha = fields[start]
            guard isObjectID(sha) else { throw GitLogParseError.notAnObjectID(sha) }
            guard let authoredAt = dates.date(from: fields[start + 4]) else {
                throw GitLogParseError.unreadableDate(fields[start + 4])
            }
            commits.append(
                CommitSummary(
                    sha: sha,
                    shortSha: fields[start + 1],
                    // Empty at a root commit; `%P` is space-separated.
                    parents: fields[start + 2].split(separator: " ").map(String.init),
                    subject: fields[start + 5],
                    authorName: fields[start + 3],
                    authoredAt: authoredAt
                ))
        }
        return commits
    }

    private static func isObjectID(_ field: String) -> Bool {
        let bytes = field.utf8
        guard objectIDLengths.contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte) || (0x41...0x46).contains(byte)
        }
    }
}
