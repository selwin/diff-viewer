import Foundation

enum LocalBranchParseError: Error, LocalizedError {
    case unreadableDate(String)
    case malformedRecord(String)

    var errorDescription: String? {
        switch self {
        case let .unreadableDate(field):
            "git for-each-ref returned an unreadable date: \(field)"
        case let .malformedRecord(line):
            "git for-each-ref returned a record without eight fields: \(line)"
        }
    }
}

/// Parses `git for-each-ref` written with the field layout in `GitClient.localBranches`:
/// one branch per line, eight NUL-separated fields — ref name, upstream short name,
/// upstream track, upstream remote name, upstream remote ref, committer date, upstream
/// full ref, tip SHA. The upstream fields may be empty; the committer date must parse.
enum LocalBranchParser {
    static func parse(_ output: String) throws -> [LocalBranch] {
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime]

        // The literal terminator, not `isNewline`, which would also split on a U+2028
        // inside a name.
        return try output.split(separator: "\n").map { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 8 else { throw LocalBranchParseError.malformedRecord(String(line)) }

            let shortName = fields[1]
            let date = fields[5]
            guard let tipCommittedAt = dates.date(from: date) else {
                throw LocalBranchParseError.unreadableDate(date)
            }
            return LocalBranch(
                name: branchName(fromRef: fields[0]),
                // No upstream name means no upstream, whatever the other fields say.
                upstream: shortName.isEmpty
                    ? nil
                    : BranchUpstream(
                        shortName: shortName,
                        remote: fields[3],
                        remoteRef: fields[4],
                        localRef: fields[6],
                        tracking: UpstreamTracking.parse(fields[2])),
                tipSha: fields[7],
                tipCommittedAt: tipCommittedAt)
        }
    }

    /// The branch name a full ref names: `refs/heads/main` → `main`. Only the line
    /// terminator is removed: git permits Unicode separators and trailing non-breaking
    /// spaces in a ref name, and trimming whitespace would corrupt those.
    static func branchName(fromRef ref: String) -> String {
        let line = ref.hasSuffix("\n") ? String(ref.dropLast()) : ref
        let prefix = "refs/heads/"
        // A ref outside `refs/heads/` is not a branch, and there is nothing better to
        // call it than what git wrote.
        guard line.hasPrefix(prefix) else { return line }
        return String(line.dropFirst(prefix.count))
    }
}
