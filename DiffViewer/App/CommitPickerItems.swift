import Foundation

/// What the window hands the commit picker on every change. The displayed commit is
/// kept apart from the loaded page: a page reset or a branch switch can drop it from the
/// page, and the picker still lists it.
struct CommitPickerSnapshot: Equatable, Sendable {
    var displayedScope: DiffScope
    /// The displayed commit's summary, when the scope is a commit and one is held.
    var displayedCommit: CommitSummary?
    /// The loaded history, in git's order.
    var commits: [CommitSummary]
    var hasMore: Bool
    var isLoadingHistory: Bool
    var historyLoadFailed: Bool
    /// Nil while unread or after a failed read.
    var workingTreeChangeCount: Int?
    var unpushedShas: Set<String>
}

/// The words on a commit row's right edge.
enum CommitPickerRowStatus: Equatable {
    case none
    /// On HEAD's branch but missing from its upstream.
    case notPushed

    var text: String {
        switch self {
        case .none: ""
        case .notPushed: "Not pushed"
        }
    }
}

struct CommitPickerWorkingTreeRow: Equatable {
    static let title = "Working Tree"

    /// `N changes`, or nil while the count is unknown.
    let detail: String?
    let isSelectedScope: Bool
}

struct CommitPickerRow: Equatable {
    let scope: DiffScope
    let sha: String
    let shortSha: String
    let subject: String
    let authorName: String
    let dateText: String
    let status: CommitPickerRowStatus
    /// The commit the diff shows, which need not be HEAD.
    let isSelectedScope: Bool
}

/// What activating an item asks the container to do.
enum CommitPickerActivation: Equatable {
    case scope(DiffScope)
    case retry
    case searchOlder
}

/// The row that ends the list whenever it is loading, failed, empty or capped. It sits
/// below whatever rows are visible, so Working Tree stays in view above it.
enum CommitPickerMessage: Equatable {
    case loading
    case failed
    case noCommits
    case noMatches(query: String)
    /// A search stopped at its budget with older commits left unread.
    case capped(searched: Int, hasMatches: Bool)

    var text: String {
        switch self {
        case .loading: "Loading…"
        case .failed: "Couldn't load history"
        case .noCommits: "No commits yet"
        case let .noMatches(query): "No commits match \"\(query)\""
        case let .capped(searched, hasMatches):
            hasMatches ? "Searched the last \(searched) commits" : "No matches in the last \(searched) commits"
        }
    }

    var showsSpinner: Bool { self == .loading }

    /// Nil for a message that only informs.
    var linkTitle: String? {
        switch action {
        case .retry: "Retry"
        case .searchOlder: "Search older commits"
        default: nil
        }
    }

    /// A message with an action is a row like any other: it takes the highlight, and
    /// activating it runs the action.
    var action: CommitPickerActivation? {
        switch self {
        case .failed: .retry
        case .capped: .searchOlder
        case .loading, .noCommits, .noMatches: nil
        }
    }
}

/// One table row.
enum CommitPickerItem: Equatable {
    enum Section: Hashable {
        /// The displayed commit, when the loaded page does not carry it.
        case selected
        case recency(RecencyGroup)

        var title: String {
            switch self {
            case .selected: "Selected"
            case let .recency(group): group.title
            }
        }
    }

    case workingTree(CommitPickerWorkingTreeRow)
    /// `firstSha` is the first commit under the header: a clock-skewed history can repeat
    /// a group, and each repeat must stay a distinct row.
    case header(Section, firstSha: String)
    case commit(CommitPickerRow)
    case message(CommitPickerMessage)

    /// What a reload matches rows by.
    enum Key: Hashable {
        case workingTree
        case header(Section, firstSha: String)
        case commit(sha: String)
        case message
    }

    var key: Key {
        switch self {
        case .workingTree: .workingTree
        case let .header(section, firstSha): .header(section, firstSha: firstSha)
        case let .commit(row): .commit(sha: row.sha)
        case .message: .message
        }
    }

    var commitRow: CommitPickerRow? {
        if case let .commit(row) = self { row } else { nil }
    }

    /// Headers and messages without an action take no highlight, hover or click.
    var activation: CommitPickerActivation? {
        switch self {
        case .workingTree: .scope(.workingTree)
        case .header: nil
        case let .commit(row): .scope(row.scope)
        case let .message(message): message.action
        }
    }
}

/// Where the highlight is. `.cleared` (the pointer left the list) is kept apart from
/// `.none` (no rows to start on yet), so arriving rows never undo the pointer leaving.
enum CommitPickerHighlight: Equatable {
    case none
    case cleared
    case row(CommitPickerItem.Key)
}

/// The header's face: the title over the detail parts and, for a commit, its short SHA.
struct CommitPickerHeaderText: Equatable {
    let title: String
    var detailParts: [String] = []
    /// Drawn monospaced after the detail parts; nil for Working Tree.
    var shortSha: String?
    /// What the copy button copies; nil for Working Tree.
    var sha: String?

    static func make(snapshot: CommitPickerSnapshot, grouping: CommitDayGrouping) -> CommitPickerHeaderText {
        switch snapshot.displayedScope {
        case .workingTree:
            return CommitPickerHeaderText(
                title: CommitPickerWorkingTreeRow.title,
                detailParts: snapshot.workingTreeChangeCount.map { [ChangeCountText.make($0)] } ?? [])
        case let .commit(ref):
            guard let commit = snapshot.displayedCommit else {
                return CommitPickerHeaderText(title: ref.shortSha, shortSha: ref.shortSha, sha: ref.sha)
            }
            return CommitPickerHeaderText(
                title: commit.subject, detailParts: [commit.author, grouping.commitDateText(for: commit.committedAt)],
                shortSha: commit.ref.shortSha, sha: commit.ref.sha)
        }
    }
}

/// What the table must do after a snapshot, a query or a budget change.
enum CommitPickerTableChange: Equatable {
    case none
    /// `removed` indexes the old items; `inserted` and `refreshed` the new ones. Rows that
    /// stay keep their cells.
    case update(removed: IndexSet, inserted: IndexSet, refreshed: IndexSet)
    case reloadAll
}
