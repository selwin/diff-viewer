import Foundation

/// A remote's URLs after `insteadOf` and `pushInsteadOf` rewrites.
struct RemoteURLs: Equatable, Sendable {
    /// The URL git fetches from.
    let fetchURL: String
    /// Every URL a push goes to; git pushes to all of them.
    let pushURLs: [String]
}

/// Parses `git remote -v`: one `name<TAB>url (fetch)` line per remote, then a
/// `name<TAB>url (push)` line per push URL. A promisor remote appends metadata such as
/// ` [blob:none]` after the direction, which is ignored.
enum RemoteURLListParser {
    static func parse(_ output: String) -> [String: RemoteURLs] {
        var fetchURLs: [String: String] = [:]
        var pushURLs: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty else { continue }
            let name = String(fields[0])
            // The direction marker is the last `(fetch)` or `(push)` token, before any trailing metadata.
            var words = fields[1].split(separator: " ", omittingEmptySubsequences: false)
            guard let direction = words.lastIndex(where: { $0 == "(fetch)" || $0 == "(push)" }) else { continue }
            let isFetch = words[direction] == "(fetch)"
            words.removeSubrange(direction...)
            let url = words.joined(separator: " ")
            if isFetch {
                if fetchURLs[name] == nil { fetchURLs[name] = url }
            } else {
                pushURLs[name, default: []].append(url)
            }
        }
        var remotes: [String: RemoteURLs] = [:]
        for (name, fetchURL) in fetchURLs {
            remotes[name] = RemoteURLs(fetchURL: fetchURL, pushURLs: pushURLs[name] ?? [])
        }
        return remotes
    }
}
