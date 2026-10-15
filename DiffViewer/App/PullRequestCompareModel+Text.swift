import Foundation

/// What the Pull Request mode's field, card and wells say.
extension PullRequestCompareModel {
    /// The default branch shows once the remote answers. Nil when no GitHub remote is known.
    var note: String? {
        guard let remote = noteRemote else { return nil }
        guard let defaultBranch else { return "Compares against \(remote)'s default branch." }
        return "Compares against \(remote)'s default branch (\(defaultBranch))."
    }

    /// The request's remote, or before there is one, the remote a `#n` would use.
    private var noteRemote: String? {
        if let request { return request.remote }
        guard case let .loaded(list) = remotes else { return nil }
        return try? PullRequestRemote.choose(for: .number(1), remotes: list).name
    }

    /// The card's resolution line; nil while idle or once resolved.
    var resolutionText: String? {
        guard let request else { return nil }
        switch resolution {
        case .resolving: return "Fetching #\(request.number) from \(request.remote)…"
        case let .failed(message): return message
        case .idle, .resolved: return nil
        }
    }

    /// Nil until the request resolves.
    func wellContent(_ side: CompareWindowModel.Side) -> CompareWellContent? {
        guard case let .resolved(range) = resolution else { return nil }
        switch side {
        case .base:
            return CompareWellContent(title: range.baseName, subtitle: "Base branch", isWarning: false)
        case .target:
            return CompareWellContent(
                title: range.targetName, subtitle: "Head · \(range.targetSHA.prefix(7))", isWarning: false)
        }
    }

    func wellPlaceholder(_ side: CompareWindowModel.Side) -> (title: String, subtitle: String) {
        switch side {
        case .base: ("Default branch", "Found when the pull request resolves")
        case .target: ("Pull request", "Paste a link to resolve it")
        }
    }
}
