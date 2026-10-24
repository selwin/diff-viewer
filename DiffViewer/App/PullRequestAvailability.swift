import Foundation

/// Whether Create Pull Request is offered for HEAD's branch. Pure, so the header pill and
/// the menu item read the same rules.
enum PullRequestAvailability: Equatable {
    case hidden
    case disabled(help: String)
    case enabled

    static let unpushedHelp = "Push first"

    /// Hidden unless HEAD's listed branch tracks a branch of a GitHub remote in
    /// `snapshot.gitHubRemoteNames`. Disabled while it has unpushed commits, or while a
    /// switch, commit or sync holds the repository.
    static func make(snapshot: BranchPickerSnapshot, isWindowEligible: Bool) -> PullRequestAvailability {
        guard isWindowEligible, snapshot.readStatus == .loaded, case let .named(name)? = snapshot.headState,
            let branch = snapshot.branches.first(where: { $0.name == name })
        else { return .hidden }
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
