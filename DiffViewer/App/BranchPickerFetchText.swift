import Foundation

/// What the branch picker's header says about fetching, with an optional tooltip.
struct BranchPickerFetchText: Equatable {
    let text: String
    var tooltip: String?

    /// The first that applies: a fetch running, a failed branch read, a failed remote,
    /// then the fetch time. Nil when nothing has been fetched this session. A running
    /// fetch names its remote when there is exactly one.
    static func make(
        isFetching: Bool, fetchingRemotes: Set<String>, readFailed: Bool, lastRound: FetchRound?, now: Date
    ) -> BranchPickerFetchText? {
        if isFetching {
            guard fetchingRemotes.count == 1, let remote = fetchingRemotes.first else {
                return BranchPickerFetchText(text: "Fetching…")
            }
            return BranchPickerFetchText(text: "Fetching from \(remote)…")
        }
        if readFailed {
            return BranchPickerFetchText(text: "Couldn't refresh branches", tooltip: "Counts may be stale")
        }
        guard let lastRound else { return nil }
        var failures = lastRound.outcomes.compactMap { remote, outcome in
            if case let .failed(message) = outcome { "\(remote): \(message)" } else { nil }
        }.sorted()
        if let discoveryError = lastRound.discoveryError {
            failures.insert("Couldn't list remotes: \(discoveryError)", at: 0)
        }
        if !failures.isEmpty {
            return BranchPickerFetchText(text: "Fetch failed — retry", tooltip: failures.joined(separator: "\n"))
        }
        // The least recent remote, so the text never claims more freshness than it has.
        let oldest = lastRound.outcomes.values.compactMap { outcome in
            if case let .fetched(at) = outcome { at } else { nil }
        }.min()
        guard let oldest else { return nil }
        return BranchPickerFetchText(text: "Fetched " + FetchedTimeText.make(at: oldest, now: now))
    }
}
