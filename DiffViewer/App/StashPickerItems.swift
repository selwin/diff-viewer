import Foundation

/// How far the window's stash read has got. `.unread` holds only until the first read
/// finishes; a later refresh keeps the last list and the status it had.
enum StashReadStatus: Equatable, Sendable {
    case unread
    case loaded
    case failed
}

/// The stash pop or drop queued or running, and the entry it acts on.
struct ActiveStashOperation: Equatable, Sendable {
    enum Operation: Equatable, Sendable {
        case pop
        case drop
    }

    let stashIndex: Int
    let sha: String
    let operation: Operation

    /// Index and sha together: either alone can name another entry once the list moves.
    func acts(on entry: StashEntry) -> Bool {
        entry.stashIndex == stashIndex && entry.sha == sha
    }
}

/// What the window hands the stash picker on every change.
struct StashPickerSnapshot: Equatable, Sendable {
    /// In git's order, newest first.
    var stashes: [StashEntry]
    var readStatus: StashReadStatus
    /// The commit scope the diff shows, nil in the working-tree scope. It need not match a
    /// listed stash; every listed entry whose ref equals it is marked displayed, so the
    /// history view of a stash's commit, which leaves out its untracked files, is not.
    var displayedRef: CommitRef?
    var activeOperation: ActiveStashOperation?
    /// Why the window refuses stash actions, from the same policy as their admission.
    var actionsBlockedReason: String?
}

struct StashPickerRow: Equatable {
    let entry: StashEntry
    /// The stash the diff shows.
    let isDisplayed: Bool
    /// Short, under a recency header that names the day.
    let timeText: String
}

/// One table row.
enum StashPickerItem: Equatable {
    case header(RecencyGroup)
    case stash(StashPickerRow)

    enum Key: Hashable {
        case header(RecencyGroup)
        /// `stashIndex` only means something within one snapshot.
        case stash(index: Int)
    }

    var key: Key {
        switch self {
        case let .header(group): .header(group)
        case let .stash(row): .stash(index: row.entry.stashIndex)
        }
    }

    var stashRow: StashPickerRow? {
        if case let .stash(row) = self { row } else { nil }
    }
}

/// Where the highlight is. `.cleared` (the pointer left the list) is kept apart from
/// `.none` (no rows to start on yet), so arriving rows never undo the pointer leaving.
enum StashPickerHighlight: Equatable {
    case none
    case cleared
    case row(StashPickerItem.Key)
}

/// What the table must do after a snapshot or a query change.
enum StashPickerTableChange: Equatable {
    case none
    /// Keys are stash indexes, which a reindex reassigns, so rows are never matched across
    /// changes.
    case reloadAll
}

/// The header's face.
struct StashPickerHeaderText: Equatable {
    let title: String
    let subtitle: String

    static func make(snapshot: StashPickerSnapshot, now: Date) -> StashPickerHeaderText {
        StashPickerHeaderText(title: "Stashes", subtitle: subtitle(snapshot, now: now))
    }

    private static func subtitle(_ snapshot: StashPickerSnapshot, now: Date) -> String {
        let stashes = snapshot.stashes
        switch snapshot.readStatus {
        case .unread: return "Loading stashes…"
        case .failed: return stashes.isEmpty ? "Couldn't read stashes" : "Couldn't refresh stashes"
        case .loaded: break
        }
        guard let newest = stashes.map(\.committedAt).max() else { return "No stashes" }
        let count = stashes.count == 1 ? "1 stash" : "\(stashes.count) stashes"
        return "\(count) · newest \(FetchedTimeText.make(at: newest, now: now))"
    }
}
