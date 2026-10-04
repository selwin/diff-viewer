import Foundation

/// A HEAD-moving operation started from the title bar, as the running text names it.
enum HeadChange: Equatable {
    case switchTo(String)
    case create(String)
    case checkoutTracking(RemoteBranch)
    case merge(MergeTarget)

    /// Switch, create, and tracking checkout clear the new-remote-branch badges.
    var clearsNewRemoteBranches: Bool {
        if case .merge = self { return false }
        return true
    }
}

/// How a merge that finished without an error changed the branch.
enum MergeKind: Equatable {
    case mergeCommit
    case fastForward
    case alreadyUpToDate
    /// The branch tip could not be read afterwards.
    case unknown
}

/// What a finished operation tells the reader.
enum HeadChangeOutcome: Equatable {
    case switched(to: String)
    case created(String)
    /// `commitCount` is nil when the cached preview provides no commit count.
    case merged(source: String, kind: MergeKind, commitCount: Int?)
    case mergeStopped(source: String, conflictFileCount: Int)
}

/// The branch pill's transient feedback: what is running, or what just happened. Text and
/// tone only; the view picks the colours.
struct HeadChangeActivity: Equatable {
    enum State: Equatable {
        case running(HeadChange)
        case finished(HeadChangeOutcome)
    }

    enum Tone: Equatable {
        case progress
        case success
        case warning
    }

    /// Grows with every activity, so an identical outcome still reads as new.
    let activityID: Int
    let state: State

    var tone: Tone {
        switch state {
        case .running: .progress
        case .finished(.mergeStopped): .warning
        case .finished: .success
        }
    }

    var title: String {
        switch state {
        case .running(.switchTo), .running(.checkoutTracking): "Switching to"
        case .running(.create): "Creating"
        case .running(.merge): "Merging"
        case .finished(.switched): "Switched to"
        case .finished(.created): "Created"
        case let .finished(.merged(_, kind, _)):
            switch kind {
            case .fastForward: "Fast-forwarded"
            case .alreadyUpToDate: "Already up to date"
            case .mergeCommit, .unknown: "Merged"
            }
        case .finished(.mergeStopped): "Merge stopped"
        }
    }

    var detail: String {
        switch state {
        case let .running(.switchTo(name)), let .running(.create(name)): name
        case let .running(.checkoutTracking(branch)): branch.name
        case let .running(.merge(target)): target.sourceName
        case let .finished(.switched(name)), let .finished(.created(name)): name
        case let .finished(.merged(source, kind, commitCount)):
            if kind != .alreadyUpToDate, let commitCount {
                "\(source) · \(Self.count(commitCount, "commit"))"
            } else {
                source
            }
        case let .finished(.mergeStopped(_, count)): "conflicts in \(Self.count(count, "file"))"
        }
    }

    /// The title and detail as one sentence for VoiceOver.
    var accessibilityText: String {
        let spoken = detail.replacingOccurrences(of: " · ", with: ", ")
        return tone == .warning ? "\(title), \(spoken)" : "\(title) \(spoken)"
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}
