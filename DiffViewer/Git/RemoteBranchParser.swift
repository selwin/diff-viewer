import Foundation

/// Parses `git for-each-ref refs/remotes/` written with the field layout in
/// `GitClient.remoteBranches`: one ref per line, four NUL-separated fields — ref name,
/// symref target, author name, committer date.
enum RemoteBranchParser {
    /// `refspecsByRemote` holds each remote's `remote.<name>.fetch` values. A ref's remote
    /// and branch come from the one mapping that stores into it, never from its path.
    static func parse(_ output: String, refspecsByRemote: [String: [String]]) throws -> [RemoteBranch] {
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime]
        let heads = "refs/heads/"

        // The literal terminator, as in `LocalBranchParser`.
        return try output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 4 else { throw BranchParseError.malformedRecord(String(line)) }
            let ref = fields[0]
            // `origin/HEAD` points at another branch; it is not one to check out.
            guard fields[1].isEmpty else { return nil }
            // Git's `--track` refuses an ambiguous ref too ("ambiguous information").
            let sources = FetchRefspecs.sources(of: ref, refspecsByRemote: refspecsByRemote)
            guard sources.count == 1, let source = sources.first, source.ref.hasPrefix(heads),
                source.ref.count > heads.count
            else { return nil }

            let date = fields[3]
            guard let tipCommittedAt = dates.date(from: date) else {
                throw BranchParseError.unreadableDate(date)
            }
            return RemoteBranch(
                remote: source.remote,
                name: String(source.ref.dropFirst(heads.count)),
                ref: ref,
                tipCommitAuthor: fields[2],
                tipCommittedAt: tipCommittedAt)
        }
    }
}
