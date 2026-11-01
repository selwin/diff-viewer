import Foundation

/// What the pull request button offers for HEAD's branch: creating one, or viewing the one
/// already open. Pure, so the header pill, the title bar and the menu item read the same rules.
enum PullRequestAvailability: Equatable {
    case hidden
    case disabled(help: String)
    case enabled
    /// HEAD's branch already has this open pull request.
    case view(GitHubPullRequest)

    static let unpushedHelp = "Push first"

    /// The state of a pull request button for this availability.
    var pickerButtonState: PickerButtonState {
        switch self {
        case .hidden: .hidden
        case let .disabled(help): .disabled(reason: help)
        case .enabled, .view: .enabled
        }
    }

    /// Whether pressing the button does something: creates or views.
    var isActionable: Bool {
        switch self {
        case .enabled, .view: true
        case .hidden, .disabled: false
        }
    }

    var title: String {
        if case let .view(pullRequest) = self { return "PR #\(pullRequest.number)" }
        return "Open PR"
    }

    func accessibilityLabel(branchName: String) -> String {
        if case let .view(pullRequest) = self { return "View pull request #\(pullRequest.number) on GitHub" }
        return "Create a pull request for \(branchName) on GitHub"
    }

    /// Hidden unless HEAD's listed branch tracks a branch of a GitHub remote in
    /// `snapshot.gitHubRemoteNames`. An open pull request found for HEAD's identity is
    /// viewed, even while the branch is ahead or busy: viewing is a read. Creating is
    /// disabled while the branch has unpushed commits, or while a switch, commit or sync
    /// holds the repository.
    static func make(snapshot: BranchPickerSnapshot, isWindowEligible: Bool) -> PullRequestAvailability {
        guard isWindowEligible, snapshot.readStatus == .loaded, case let .named(name)? = snapshot.headState,
            let branch = snapshot.branches.first(where: { $0.name == name })
        else { return .hidden }
        if let lookup = snapshot.pullRequestLookup, let pullRequest = lookup.pullRequest,
            lookup.identity == snapshot.currentPullRequestIdentity
        {
            return .view(pullRequest)
        }
        let availability = make(branch: branch, gitHubRemoteNames: snapshot.gitHubRemoteNames)
        guard availability != .hidden else { return .hidden }
        if let busy = SyncPolicy.busyReason(
            active: snapshot.activeSync, isSwitching: snapshot.isSwitchingBranch, isCommitting: snapshot.isCommitting)
        {
            return .disabled(help: busy)
        }
        return availability
    }

    /// The branch's own part: an upstream under `refs/heads/` on a GitHub remote, with
    /// nothing left to push. Behind is fine; the pull request shows what was pushed.
    static func make(branch: LocalBranch, gitHubRemoteNames: Set<String>) -> PullRequestAvailability {
        guard let upstream = branch.upstream, case let .counts(ahead, _) = upstream.tracking,
            upstream.remoteRef.hasPrefix("refs/heads/"), gitHubRemoteNames.contains(upstream.remote)
        else { return .hidden }
        return ahead > 0 ? .disabled(help: unpushedHelp) : .enabled
    }
}
