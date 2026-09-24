import Foundation

/// The ways the picker moves commits between a branch and a remote. A publish pushes a
/// branch that tracks nothing and makes the remote branch its upstream.
enum SyncOperation: Equatable, Sendable {
    case pull
    case push
    case publish
}

/// The operation in flight, and the branch it was started on.
struct ActiveSync: Equatable, Sendable {
    let branch: String
    let operation: SyncOperation
}

/// What a picker button shows. A reason is a tooltip: the button says what it would do,
/// the tooltip why it cannot.
enum PickerButtonState: Equatable {
    case hidden
    case enabled
    case disabled(reason: String)
    case running
}

/// Where Publish sends a branch that tracks nothing.
enum PublishRemote: Equatable {
    /// No remotes: there is nowhere to publish.
    case none
    case remote(String)
    /// Several remotes and no origin: the reader picks one.
    case ask([String])
}

/// One remote in Publish's menu. A remote being fetched is listed but can't be picked.
struct PublishMenuItem: Equatable {
    let remote: String
    let isEnabled: Bool
}

/// What a click on an enabled Publish does.
enum PublishAction: Equatable {
    case remote(String)
    case menu([PublishMenuItem])
}

/// One branch row's Pull and Push buttons. Push is titled Publish on a branch that
/// tracks nothing.
struct RowSyncButtons: Equatable {
    var pull: PickerButtonState
    var push: PickerButtonState
    var pushTitle = "Push"
    /// Set only on an enabled Publish.
    var publish: PublishAction?

    static let hidden = RowSyncButtons(pull: .hidden, push: .hidden)
}

/// A publish as the reader asked for it. Checked again before it runs, so a branch that
/// gained an upstream or lost its remote in the meantime is left alone.
struct PublishRequest: Equatable, Sendable {
    let branch: String
    let remote: String
}

/// The exact refs an operation was asked for. Compared before it runs, so a retargeted
/// upstream between the click and the turn on the write chain cancels it rather than
/// acting somewhere else.
struct SyncDestination: Equatable, Sendable {
    let branch: String
    let remote: String
    let remoteRef: String
    /// The remote-tracking ref the counts compare against, which a fast-forward updates.
    let localRef: String
}

/// A destination plus how far apart the two sides were at the last read.
struct SyncTarget: Equatable {
    let destination: SyncDestination
    let ahead: Int
    let behind: Int
}

/// What the picker may offer, and what it may do, given a branch read. Pure, so the rules
/// can be read and tested on their own.
enum SyncPolicy {
    /// Nil unless the read landed, `branch` is in the list, and it tracks a remote
    /// upstream with counts. A gone or unread upstream says nothing about where a pull or
    /// a push would go, and a local upstream (remote `.`, or a ref outside
    /// `refs/remotes/`) is out of scope.
    static func target(branch: String, readStatus: BranchReadStatus, branches: [LocalBranch]) -> SyncTarget? {
        guard let found = branches.first(where: { $0.name == branch }) else { return nil }
        return target(for: found, readStatus: readStatus)
    }

    /// The same rules for a branch already in hand.
    static func target(for branch: LocalBranch, readStatus: BranchReadStatus) -> SyncTarget? {
        guard readStatus == .loaded, let upstream = branch.upstream,
            upstream.remote != ".", upstream.localRef.hasPrefix("refs/remotes/"),
            case let .counts(ahead, behind) = upstream.tracking
        else { return nil }
        return SyncTarget(
            destination: SyncDestination(
                branch: branch.name, remote: upstream.remote, remoteRef: upstream.remoteRef,
                localRef: upstream.localRef),
            ahead: ahead, behind: behind)
    }

    /// A pull needs something to take, and a branch that isn't checked out can only
    /// fast-forward. A push needs something to send and a fast-forward to send it on.
    /// A branch with a target already tracks something, so it has nothing to publish.
    static func allows(_ operation: SyncOperation, on target: SyncTarget, isCurrent: Bool) -> Bool {
        switch operation {
        case .pull: target.behind > 0 && (isCurrent || target.ahead == 0)
        case .push: target.ahead > 0 && target.behind == 0
        case .publish: false
        }
    }

    /// origin when there is one, else the only remote; with several and no origin, the
    /// reader is asked.
    static func publishRemote(remotes: [String]) -> PublishRemote {
        if remotes.contains("origin") { return .remote("origin") }
        if remotes.count == 1, let only = remotes.first { return .remote(only) }
        return remotes.isEmpty ? .none : .ask(remotes)
    }

    /// The remote a branch is configured to track when git reads it as tracking nothing:
    /// the remote's fetch settings don't cover the upstream. Publishing would rewrite
    /// that config, so the branch is left for the reader to sort out.
    static func hiddenUpstreamRemote(of branch: LocalBranch, configuredRemote: String?) -> String? {
        branch.upstream == nil ? configuredRemote : nil
    }

    /// The branch is listed, tracks nothing, not even through config the fetch settings
    /// hide, and the chosen remote still exists.
    static func canPublish(
        _ request: PublishRequest, branches: [LocalBranch], remotes: [String], configuredRemote: String?
    ) -> Bool {
        guard let branch = branches.first(where: { $0.name == request.branch }) else { return false }
        return branch.upstream == nil && configuredRemote == nil && remotes.contains(request.remote)
    }

    /// Whether a fetch may still move `target`'s counts: remote discovery (it may pick
    /// that remote) or a fetch of its remote. Other remotes' fetches don't count.
    static func isFetching(target: SyncTarget?, fetchStatus: FetchStatus, fetchingRemotes: Set<String>) -> Bool {
        if fetchStatus == .fetching(remote: nil) { return true }
        guard let target else { return false }
        return fetchingRemotes.contains(target.destination.remote)
    }

    // swiftlint:disable function_parameter_count
    /// One row's buttons. The operation in flight on this row decides first, so the
    /// button the reader clicked keeps its spinner even while the refresh behind it moves
    /// the counts or takes the target away. The other button keeps the visibility the
    /// counts give it: a hidden Pull does not surface, greyed, just because a push runs.
    /// A branch that tracks nothing gets Publish in Push's place.
    static func rowButtons(
        branch: LocalBranch, isCurrent: Bool, readStatus: BranchReadStatus, active: ActiveSync?,
        isSwitching: Bool, isDiscovering: Bool, fetchingRemotes: Set<String>, remotes: [String],
        configuredRemote: String?
    ) -> RowSyncButtons {
        let target = target(for: branch, readStatus: readStatus)
        let showsPull = (target?.behind ?? 0) > 0
        let showsPush = (target?.ahead ?? 0) > 0
        if let active, active.branch == branch.name {
            switch active.operation {
            case .pull: return RowSyncButtons(pull: .running, push: showsPush ? .disabled(reason: "Pulling…") : .hidden)
            case .push: return RowSyncButtons(pull: showsPull ? .disabled(reason: "Pushing…") : .hidden, push: .running)
            case .publish: return RowSyncButtons(pull: .hidden, push: .running, pushTitle: "Publish")
            }
        }
        // Whatever else is running holds the repository, so a visible button waits it out
        // rather than disappearing.
        let busy: String? =
            if let active {
                switch active.operation {
                case .pull: "Pulling \(active.branch)…"
                case .push: "Pushing \(active.branch)…"
                case .publish: "Publishing \(active.branch)…"
                }
            } else if isSwitching {
                "Switching branch…"
            } else {
                nil
            }
        if readStatus == .loaded, branch.upstream == nil {
            return publishButtons(
                hiddenRemote: hiddenUpstreamRemote(of: branch, configuredRemote: configuredRemote),
                choice: publishRemote(remotes: remotes), busy: busy, isDiscovering: isDiscovering,
                fetchingRemotes: fetchingRemotes)
        }
        guard let target else { return .hidden }
        let waiting = busy ?? (isDiscovering || fetchingRemotes.contains(target.destination.remote) ? "Fetching…" : nil)
        let diverged = showsPull && showsPush
        let pull: PickerButtonState
        if !showsPull {
            pull = .hidden
        } else if let waiting {
            pull = .disabled(reason: waiting)
        } else {
            // A branch that isn't checked out can only fast-forward.
            pull = diverged && !isCurrent ? .disabled(reason: "Has local commits; switch to it to pull") : .enabled
        }
        let push: PickerButtonState
        if !showsPush {
            push = .hidden
        } else if let waiting {
            push = .disabled(reason: waiting)
        } else {
            // Diverged: a fast-forward push would be refused, and the pull comes first.
            push = diverged ? .disabled(reason: "Pull first") : .enabled
        }
        return RowSyncButtons(pull: pull, push: push)
    }
    // swiftlint:enable function_parameter_count

    /// Publish for a branch that tracks nothing. It waits on remote discovery, which may
    /// add or remove remotes, and on a fetch of the remote it would go to. With a menu,
    /// only the remote being fetched waits.
    private static func publishButtons(
        hiddenRemote: String?, choice: PublishRemote, busy: String?, isDiscovering: Bool,
        fetchingRemotes: Set<String>
    ) -> RowSyncButtons {
        let action: PublishAction
        let remoteIsFetching: Bool
        switch choice {
        case .none:
            return .hidden
        case let .remote(remote):
            action = .remote(remote)
            remoteIsFetching = fetchingRemotes.contains(remote)
        case let .ask(remotes):
            action = .menu(remotes.map { PublishMenuItem(remote: $0, isEnabled: !fetchingRemotes.contains($0)) })
            remoteIsFetching = false
        }
        if let hiddenRemote {
            return RowSyncButtons(
                pull: .hidden, push: .disabled(reason: "Tracks \(hiddenRemote), but fetch settings don't fetch it"),
                pushTitle: "Publish")
        }
        if let waiting = busy ?? (isDiscovering || remoteIsFetching ? "Fetching…" : nil) {
            return RowSyncButtons(pull: .hidden, push: .disabled(reason: waiting), pushTitle: "Publish")
        }
        return RowSyncButtons(pull: .hidden, push: .enabled, pushTitle: "Publish", publish: action)
    }
}
