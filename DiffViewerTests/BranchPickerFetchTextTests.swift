import Foundation
import Testing

@testable import DiffViewer

struct BranchPickerFetchTextTests {
    private let now = Date(timeIntervalSince1970: 1_789_300_000)

    private func make(
        isFetching: Bool = false, readFailed: Bool = false, lastRound: FetchRound?
    ) -> BranchPickerFetchText? {
        BranchPickerFetchText.make(isFetching: isFetching, readFailed: readFailed, lastRound: lastRound, now: now)
    }

    private var failed: FetchRound {
        FetchRound(outcomes: ["origin": .failed(message: "host down")])
    }

    @Test func aRunningFetchComesFirst() {
        #expect(make(isFetching: true, readFailed: true, lastRound: failed) == BranchPickerFetchText(text: "Fetching…"))
    }

    @Test func aFailedReadOutranksTheFetchOutcome() {
        let expected = BranchPickerFetchText(text: "Couldn't refresh branches", tooltip: "Counts may be stale")
        #expect(make(readFailed: true, lastRound: failed) == expected)
        #expect(make(readFailed: true, lastRound: nil) == expected)
    }

    @Test func oneFailedRemoteFailsTheRoundAndTheTooltipNamesEveryFailure() {
        let round = FetchRound(outcomes: [
            "origin": .fetched(at: now),
            "upstream": .failed(message: "timed out"),
            "fork": .failed(message: "host down"),
        ])
        #expect(
            make(lastRound: round)
                == BranchPickerFetchText(text: "Fetch failed — retry", tooltip: "fork: host down\nupstream: timed out"))
    }

    @Test func aFailedDiscoveryIsAFailedRound() {
        let round = FetchRound(discoveryError: "not a git repository")
        #expect(
            make(lastRound: round)
                == BranchPickerFetchText(
                    text: "Fetch failed — retry", tooltip: "Couldn't list remotes: not a git repository"))
    }

    /// The least recent remote decides, so the text never claims more freshness than it has.
    @Test func successReportsTheOldestFetch() {
        let round = FetchRound(outcomes: ["origin": .fetched(at: now - 30), "fork": .fetched(at: now - 600)])
        #expect(make(lastRound: round) == BranchPickerFetchText(text: "Fetched 10 min ago"))
    }

    @Test func nothingFetchedSaysNothing() {
        #expect(make(lastRound: nil) == nil)
        #expect(make(lastRound: FetchRound()) == nil, "a repository without remotes")
    }
}
