import Foundation

/// The header's face: where HEAD is, how far it is from its upstream, whether the GitHub CLI
/// can find pull requests, and the current branch's Pull, Push and pull request button.
struct BranchPickerHeaderText: Equatable {
    let title: String
    /// What the detail line says about HEAD's upstream; the fetch news follows.
    var detailParts: [String] = []
    /// True while a fetch round runs, whether or not its remotes are known yet.
    var showsSpinner = false
    /// Fetch is offered unless a round is running or a pull or push is about to move the
    /// same counts, which a round would not start beside.
    var canFetch = true
    /// HEAD's branch, which `buttons` act on; nil when HEAD is on no listed branch.
    var branch: String?
    var buttons = RowSyncButtons.hidden
    var pullRequest = PullRequestAvailability.hidden
    /// What the title's copy button copies: HEAD's branch name, listed or not yet. Nil
    /// when HEAD is detached or unread.
    var copyableName: String?
    /// `gh`'s login, shown only in a repository with a GitHub remote: it decides whether
    /// existing pull requests can be found.
    var gitHub: GitHubCLIStatus?

    /// A header button Tab can reach.
    enum Control: Equatable {
        case copy
        case fetch
        case pull
        case push
        case pullRequest
    }

    /// The header buttons Tab visits after the search field, in order: only those shown
    /// and enabled, so focus never lands on a button that can't act.
    var focusOrder: [Control] {
        var order: [Control] = copyableName == nil ? [] : [.copy]
        if canFetch { order.append(.fetch) }
        guard branch != nil else { return order }
        if buttons.pull == .enabled { order.append(.pull) }
        if buttons.push == .enabled { order.append(.push) }
        if pullRequest.isActionable { order.append(.pullRequest) }
        return order
    }

    /// The detail line: the upstream, the fetch news, then the GitHub CLI.
    func detail(fetch: BranchPickerFetchText?) -> String {
        (detailParts + [fetch?.text ?? "", gitHubText?.text ?? ""]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The detail line's tooltip: the fetch's, then the GitHub CLI's, one per line.
    func detailTooltip(fetch: BranchPickerFetchText?) -> String? {
        let lines = [fetch?.tooltip, gitHubText?.tooltip].compactMap(\.self)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The GitHub CLI's part of the detail line and what its tooltip explains.
    var gitHubText: (text: String, tooltip: String)? {
        switch gitHub {
        case nil:
            nil
        case let .signedIn(login):
            ("GitHub: \(login)", "Finding pull requests with the GitHub CLI, signed in as \(login)")
        case .signedOut:
            (
                "GitHub CLI signed out",
                "Sign in with `gh auth login --hostname github.com` to find existing pull requests"
            )
        case .notInstalled:
            ("GitHub CLI not installed", "Install the GitHub CLI (gh) to find existing pull requests")
        case let .failed(message):
            ("GitHub CLI unavailable", message)
        }
    }

    static func make(snapshot: BranchPickerSnapshot) -> BranchPickerHeaderText {
        let spinner = snapshot.fetchStatus != .idle
        let canFetch = !spinner && snapshot.activeSync == nil
        // Repository-level, so every path below carries it.
        let gitHub = snapshot.gitHubRemoteNames.isEmpty ? nil : snapshot.gitHubCLIStatus
        guard let headState = snapshot.headState else {
            let title = snapshot.readStatus == .failed ? "Couldn't read branches" : "Loading…"
            return BranchPickerHeaderText(title: title, showsSpinner: spinner, canFetch: canFetch, gitHub: gitHub)
        }
        switch headState {
        case .detached:
            return BranchPickerHeaderText(
                title: headState.displayTitle, showsSpinner: spinner, canFetch: canFetch, gitHub: gitHub)
        case let .named(name):
            // A branch missing from the list says nothing: the counts are what the list holds.
            guard let branch = snapshot.branches.first(where: { $0.name == name }) else {
                return BranchPickerHeaderText(
                    title: name, showsSpinner: spinner, canFetch: canFetch, copyableName: name, gitHub: gitHub)
            }
            // Worded as the row is, so a hidden upstream reads the same in both places, but
            // capitalised: it starts the detail line. Up to date says nothing.
            let status = BranchRowStatus.local(branch, configuredRemote: snapshot.configuredUpstreamRemotes[name])
            let detailParts = status == .none ? [] : [status.text.prefix(1).uppercased() + status.text.dropFirst()]
            return BranchPickerHeaderText(
                title: name, detailParts: detailParts, showsSpinner: spinner,
                canFetch: canFetch, branch: name,
                buttons: BranchPickerState.syncButtons(for: branch, isCurrent: true, snapshot: snapshot),
                // The picker only opens in a window that can offer it.
                pullRequest: PullRequestAvailability.make(snapshot: snapshot, isWindowEligible: true),
                copyableName: name, gitHub: gitHub)
        }
    }
}
