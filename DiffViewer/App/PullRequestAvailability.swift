import Foundation

/// Whether HEAD's branch offers to create a pull request or to view the one it has. Pure,
/// so the header pill and the menu item read the same rules.
enum PullRequestAvailability: Equatable {
    case hidden
    case disabled(help: String)
    case enabled
    /// The branch already has pull request `number`, at `url`.
    case existing(number: Int, url: URL)

    static let unpushedHelp = "Push first"

    /// The state of the pull request button for this availability.
    var pickerButtonState: PickerButtonState {
        switch self {
        case .hidden: .hidden
        case let .disabled(help): .disabled(reason: help)
        case .enabled, .existing: .enabled
        }
    }

    /// The header button's title.
    var buttonTitle: String {
        if case let .existing(number, _) = self { "View PR #\(number)" } else { "Open PR" }
    }

    /// The Repository menu item's title.
    var menuTitle: String {
        if case let .existing(number, _) = self {
            "View Pull Request #\(number) on GitHub"
        } else {
            "Create Pull Request on GitHub"
        }
    }

    /// The button's tooltip while it can act; a disabled button shows its reason.
    var help: String {
        switch self {
        case let .existing(number, _): "View pull request #\(number) on GitHub"
        case let .disabled(help): help
        case .hidden, .enabled: "Create a pull request on GitHub"
        }
    }

    /// Hidden unless HEAD's listed branch tracks a branch of a GitHub remote in
    /// `snapshot.gitHubRemoteNames`. A pull request found for it is offered whatever else
    /// holds; otherwise creating one is disabled while the branch has unpushed commits, or
    /// while a switch, commit or sync holds the repository.
    static func make(snapshot: BranchPickerSnapshot, isWindowEligible: Bool) -> PullRequestAvailability {
        guard isWindowEligible, snapshot.readStatus == .loaded, case let .named(name)? = snapshot.headState,
            let branch = snapshot.branches.first(where: { $0.name == name })
        else { return .hidden }
        let availability = make(branch: branch, gitHubRemoteNames: snapshot.gitHubRemoteNames)
        guard availability != .hidden else { return .hidden }
        if let existing = snapshot.existingPullRequest {
            return .existing(number: existing.number, url: existing.url)
        }
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
