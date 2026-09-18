import Foundation

/// What a file's line counts were computed from. Only equal, fully known inputs justify
/// reusing an earlier result; anything the fingerprint could not describe is `.unknown`
/// and is recomputed every time.
enum FileInputIdentity: Equatable {
    case known(DiffInputFingerprint)
    case unknown

    init(_ fingerprint: DiffInputFingerprint?) {
        if let fingerprint, fingerprint.isKnown {
            self = .known(fingerprint)
        } else {
            self = .unknown
        }
    }
}

/// Everything a line-stats read depends on. Two equal requests would produce the same
/// counts, provided every input is known.
struct LineStatsRequest: Equatable {
    let scope: DiffScope
    let hideWhitespace: Bool
    /// The session's revision of git configuration that affects diffs (attributes, excludes).
    let configurationRevision: Int
    /// Every requested file, listed explicitly so a file that appears or disappears
    /// changes the request.
    let inputs: [ChangedFile.ID: FileInputIdentity]

    var isKnown: Bool { inputs.values.allSatisfy { $0 != .unknown } }
}

/// One file's share of a finished read. `.available(.binary)` is a successful result
/// (the sidebar labels it); `.unavailable` means no counts apply; `.failed` may be retried.
enum LineStatsResult: Equatable {
    case available(LineStats)
    case unavailable
    case failed
}

/// A finished read, kept with the request it answered so a later request can be matched
/// against it.
struct LineStatsOutcome: Equatable {
    let request: LineStatsRequest
    let results: [ChangedFile.ID: LineStatsResult]

    var hasFailures: Bool { results.values.contains(.failed) }
}

/// Decides whether a line-stats read can be reused, is already running, or must start,
/// and identifies each read by a token. Pure on purpose: it owns no task, so the caller
/// cancels or starts work according to the transition it gets back.
struct LineStatsState {
    /// The read in flight, if any, and the token its result must carry.
    private(set) var activeRequest: (request: LineStatsRequest, token: Int)?
    /// The most recent finished read.
    private(set) var lastOutcome: LineStatsOutcome?
    private var nextToken = 0

    enum Transition: Equatable {
        /// `lastOutcome` answers the request; the active read, if any, is now stale.
        case reuseLastOutcome(cancelActive: Bool)
        /// The active read is already computing this request.
        case keepActive
        /// Start a read that reports back with `token`, cancelling the active one first.
        case start(token: Int, cancelActive: Bool)
    }

    /// Chooses the transition for `desired`.
    ///
    /// `.manual` always starts: ⌘R is the user's "re-read everything", and the stated
    /// fallback for changes the watcher cannot see. Otherwise an equal active request is
    /// kept, whether its inputs are known or not: repeated ticks must not restart the
    /// work, and an unchanged tick must not cancel a ⌘R or a retry already running for
    /// the same inputs. Failing that, the last outcome is reused when it answered an
    /// equal, fully known request — and, if it holds failures, only for a watcher tick,
    /// so every other action retries. Reuse cancels a *different* active request.
    mutating func decide(desired: LineStatsRequest, cause: RefreshCause) -> Transition {
        if cause != .manual {
            if activeRequest?.request == desired {
                return .keepActive
            }
            if let last = lastOutcome, last.request == desired, desired.isKnown,
                !last.hasFailures || cause == .watcher
            {
                let cancelActive = activeRequest != nil
                activeRequest = nil
                return .reuseLastOutcome(cancelActive: cancelActive)
            }
        }
        let cancelActive = activeRequest != nil
        nextToken += 1
        activeRequest = (desired, nextToken)
        return .start(token: nextToken, cancelActive: cancelActive)
    }

    /// Stores `outcome` as the last one. Returns false, changing nothing, when `token`
    /// is not the active read's: that read was superseded and its result is dropped.
    mutating func record(_ outcome: LineStatsOutcome, token: Int) -> Bool {
        guard activeRequest?.token == token else { return false }
        lastOutcome = outcome
        activeRequest = nil
        return true
    }

    /// Drops the active read and returns its token so the caller can cancel it. For
    /// `close()` and scope changes, where no result is wanted any more.
    mutating func invalidateActive() -> Int? {
        defer { activeRequest = nil }
        return activeRequest?.token
    }
}

// MARK: - Carry-over

extension LineStatsResult {
    /// What the sidebar shows: counts for a success, nothing for the other two. Only
    /// this projection collapses `.unavailable` and `.failed`.
    var lineStats: LineStats? {
        if case let .available(stats) = self { return stats }
        return nil
    }
}

extension LineStatsOutcome {
    /// The counts this outcome still answers for `file` under `desired`: the same scope,
    /// whitespace mode and configuration, and the file's inputs fully known and unmoved.
    /// Unknown inputs never reuse, so a file the fingerprint cannot describe is recounted.
    func validStats(for file: ChangedFile, in desired: LineStatsRequest) -> LineStats? {
        guard request.scope == desired.scope, request.hideWhitespace == desired.hideWhitespace,
            request.configurationRevision == desired.configurationRevision,
            case let .known(fingerprint)? = request.inputs[file.id],
            !DiffInputFingerprint.mayHaveChanged(fingerprint, file.fingerprint)
        else { return nil }
        return results[file.id]?.lineStats
    }
}
