import Foundation

/// Parses `git for-each-ref` written with the field layout in `GitClient.refs`: one ref
/// per line, eight NUL-separated fields — ref name, symref target, object type, object
/// name, committer date (unix), then the object type, name and committer date the ref
/// peels to. The peeled fields are empty unless the ref is an annotated tag.
enum GitRefParser {
    static func parse(_ output: String) throws -> [GitRef] {
        // Split only on LF; Unicode separators are valid in ref names.
        try output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 8 else { throw BranchParseError.malformedRecord(String(line)) }
            // `origin/HEAD` points at another ref; listing it would duplicate that ref.
            guard fields[1].isEmpty else { return nil }

            let sha: String
            let date: String
            if fields[2] == "commit" {
                sha = fields[3]
                date = fields[4]
            } else if fields[2] == "tag", fields[5] == "commit" {
                // A tag object has no committer date; the commit it names does.
                sha = fields[6]
                date = fields[7]
            } else {
                // A tag of a tree or blob names no commit to compare.
                return nil
            }
            guard let seconds = TimeInterval(date) else { throw BranchParseError.unreadableDate(date) }

            let fullName = fields[0]
            guard let (name, kind) = nameAndKind(of: fullName) else { return nil }
            return GitRef(
                fullName: fullName, name: name, kind: kind, commitSHA: sha,
                committedAt: Date(timeIntervalSince1970: seconds))
        }
    }

    private static func nameAndKind(of fullName: String) -> (String, GitRef.Kind)? {
        let prefixes: [(String, GitRef.Kind)] = [
            ("refs/heads/", .local), ("refs/remotes/", .remote), ("refs/tags/", .tag),
        ]
        for (prefix, kind) in prefixes where fullName.hasPrefix(prefix) {
            return (String(fullName.dropFirst(prefix.count)), kind)
        }
        return nil
    }
}
