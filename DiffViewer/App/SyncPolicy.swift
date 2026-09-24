import Foundation

/// The two ways the picker moves commits between a branch and its upstream.
enum SyncOperation: Equatable, Sendable {
    case pull
    case push
}

/// What a picker button shows. A reason is a tooltip: the button says what it would do,
/// the tooltip why it cannot.
enum PickerButtonState: Equatable {
    case hidden
    case enabled
    case disabled(reason: String)
    case running
}

/// The exact refs an operation was asked for. Compared before it runs, so a branch switch
/// or a retargeted upstream between the click and the turn on the write chain cancels it
/// rather than acting somewhere else.
struct SyncDestination: Equatable, Sendable {
    let branch: String
    let remote: String
    let remoteRef: String
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
    /// Nil unless the read landed, HEAD is on a branch that is in the list, and that
    /// branch tracks an upstream with counts: a gone or unread upstream says nothing about
    /// where a pull or a push would go.
    static func target(readStatus: BranchReadStatus, headState: HeadState?, branches: [LocalBranch]) -> SyncTarget? {
        guard readStatus == .loaded, case let .named(name)? = headState,
            let upstream = branches.first(where: { $0.name == name })?.upstream,
            case let .counts(ahead, behind) = upstream.tracking
        else { return nil }
        return SyncTarget(
            destination: SyncDestination(branch: name, remote: upstream.remote, remoteRef: upstream.remoteRef),
            ahead: ahead, behind: behind)
    }

    /// A pull needs something to take; a push needs something to send and a fast-forward
    /// to send it on.
    static func allows(_ operation: SyncOperation, on target: SyncTarget) -> Bool {
        switch operation {
        case .pull: target.behind > 0
        case .push: target.ahead > 0 && target.behind == 0
        }
    }

    /// Whether a fetch holds the counts `target` is drawn from: remote discovery might
    /// still resolve to its remote, and a fetch of that remote is still moving them.
    /// Fetches of other remotes leave it alone.
    static func isFetching(target: SyncTarget?, fetchStatus: FetchStatus, fetchingRemotes: Set<String>) -> Bool {
        if fetchStatus == .fetching(remote: nil) { return true }
        guard let target else { return false }
        return fetchingRemotes.contains(target.destination.remote)
    }

    /// The two buttons' states. The operation in flight decides first, so the button the
    /// reader clicked keeps its spinner even while the refresh behind it moves the counts
    /// or takes the target away. The other button keeps the visibility the counts give
    /// it: a hidden Pull does not surface, greyed, just because a push is running.
    static func buttons(
        target: SyncTarget?, active: SyncOperation?, isSwitching: Bool, isFetching: Bool
    ) -> (pull: PickerButtonState, push: PickerButtonState) {
        let showsPull = (target?.behind ?? 0) > 0
        let showsPush = (target?.ahead ?? 0) > 0
        switch active {
        case .pull: return (.running, showsPush ? .disabled(reason: "Pulling…") : .hidden)
        case .push: return (showsPull ? .disabled(reason: "Pushing…") : .hidden, .running)
        case nil: break
        }
        // Whatever else is running holds the repository, so a visible button waits it out
        // rather than disappearing.
        let busy: String? = isSwitching ? "Switching branch…" : (isFetching ? "Fetching…" : nil)
        let pull: PickerButtonState = showsPull ? busy.map { .disabled(reason: $0) } ?? .enabled : .hidden
        let push: PickerButtonState
        if !showsPush {
            push = .hidden
        } else if let busy {
            push = .disabled(reason: busy)
        } else {
            // Diverged: a fast-forward push would be refused, and the pull comes first.
            push = showsPull ? .disabled(reason: "Pull first") : .enabled
        }
        return (pull, push)
    }
}
