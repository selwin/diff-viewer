import Foundation

/// The two ways the picker moves commits between a branch and its upstream.
enum SyncOperation: Equatable, Sendable {
    case pull
    case push
}

/// The pull or push in flight, and the branch it was started on.
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

/// One branch row's Pull and Push buttons.
struct RowSyncButtons: Equatable {
    var pull: PickerButtonState
    var push: PickerButtonState
    var pushTitle = "Push"

    static let hidden = RowSyncButtons(pull: .hidden, push: .hidden)
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
    static func allows(_ operation: SyncOperation, on target: SyncTarget, isCurrent: Bool) -> Bool {
        switch operation {
        case .pull: target.behind > 0 && (isCurrent || target.ahead == 0)
        case .push: target.ahead > 0 && target.behind == 0
        }
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
    static func rowButtons(
        branch: LocalBranch, isCurrent: Bool, readStatus: BranchReadStatus, active: ActiveSync?,
        isSwitching: Bool, isDiscovering: Bool, fetchingRemotes: Set<String>
    ) -> RowSyncButtons {
        let target = target(for: branch, readStatus: readStatus)
        let showsPull = (target?.behind ?? 0) > 0
        let showsPush = (target?.ahead ?? 0) > 0
        if let active, active.branch == branch.name {
            switch active.operation {
            case .pull: return RowSyncButtons(pull: .running, push: showsPush ? .disabled(reason: "Pulling…") : .hidden)
            case .push: return RowSyncButtons(pull: showsPull ? .disabled(reason: "Pushing…") : .hidden, push: .running)
            }
        }
        guard let target else { return .hidden }
        // Whatever else is running holds the repository, so a visible button waits it out
        // rather than disappearing.
        let busy: String? =
            if let active {
                active.operation == .pull ? "Pulling \(active.branch)…" : "Pushing \(active.branch)…"
            } else if isSwitching {
                "Switching branch…"
            } else if isDiscovering || fetchingRemotes.contains(target.destination.remote) {
                "Fetching…"
            } else {
                nil
            }
        let diverged = showsPull && showsPush
        let pull: PickerButtonState
        if !showsPull {
            pull = .hidden
        } else if let busy {
            pull = .disabled(reason: busy)
        } else {
            // A branch that isn't checked out can only fast-forward.
            pull = diverged && !isCurrent ? .disabled(reason: "Has local commits; switch to it to pull") : .enabled
        }
        let push: PickerButtonState
        if !showsPush {
            push = .hidden
        } else if let busy {
            push = .disabled(reason: busy)
        } else {
            // Diverged: a fast-forward push would be refused, and the pull comes first.
            push = diverged ? .disabled(reason: "Pull first") : .enabled
        }
        return RowSyncButtons(pull: pull, push: push)
    }
    // swiftlint:enable function_parameter_count
}
