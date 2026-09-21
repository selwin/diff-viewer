import Foundation
import Testing

@testable import DiffViewer

struct UpstreamTrackingTests {
    @Test func anEmptyFieldIsUpToDate() {
        #expect(UpstreamTracking.parse("") == .counts(ahead: 0, behind: 0))
    }

    @Test func goneIsItsOwnCase() {
        #expect(UpstreamTracking.parse("gone") == .gone)
    }

    @Test func aheadOnly() {
        #expect(UpstreamTracking.parse("ahead 7") == .counts(ahead: 7, behind: 0))
    }

    @Test func behindOnly() {
        #expect(UpstreamTracking.parse("behind 2") == .counts(ahead: 0, behind: 2))
    }

    @Test func aheadAndBehind() {
        #expect(UpstreamTracking.parse("ahead 1, behind 2") == .counts(ahead: 1, behind: 2))
    }

    /// Anything unrecognised reads as up to date, which shows nothing on the face.
    @Test func anUnknownFieldIsUpToDate() {
        #expect(UpstreamTracking.parse("sideways 3") == .counts(ahead: 0, behind: 0))
    }

    @Test func upToDateHasNothingToSay() {
        #expect(UpstreamTracking.counts(ahead: 0, behind: 0).summary == nil)
    }

    /// Behind first: it is the count that decides whether a pull is due.
    @Test func bothCountsReadBehindFirst() {
        #expect(UpstreamTracking.counts(ahead: 1, behind: 2).summary == "2 behind, 1 ahead")
    }

    @Test func oneSidedSummaries() {
        #expect(UpstreamTracking.counts(ahead: 3, behind: 0).summary == "3 ahead")
        #expect(UpstreamTracking.counts(ahead: 0, behind: 2).summary == "2 behind")
    }

    @Test func goneSaysSo() {
        #expect(UpstreamTracking.gone.summary == "upstream gone")
    }
}
