import Observation

/// A window's stash list and how its last read went. Its own object so the window's
/// class body stays small; `WindowState+StashPicker` reads into it on a ticket.
@MainActor @Observable
final class StashList {
    /// Newest first. A failed read keeps the last list on show: stale beats blank.
    private(set) var entries: [StashEntry] = []
    private(set) var readStatus: StashReadStatus = .unread

    /// Takes a read's result: a list, or nil for a failure.
    func publish(_ list: [StashEntry]?) {
        guard let list else {
            readStatus = .failed
            return
        }
        if list != entries { entries = list }
        readStatus = .loaded
    }
}
